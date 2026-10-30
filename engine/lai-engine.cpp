// lai-engine: loads one GGUF model and serves chat requests over stdin/stdout.
//
// Built on libllama plus llama.cpp's chat helpers (Jinja chat templates and
// tool-call parsing). No HTTP, web UI, multimodal or router code.
//
// Protocol, one JSON object per line:
//   engine -> lai  {"ready":true,"ctx":N}                          once, after loading
//   lai -> engine  {"messages":[...],"tools":[...],"temperature":T,"top_p":P,"top_k":K,
//                   "min_p":M,"repeat_penalty":R,"max_tokens":N,"thinking":B}   all optional
//                  messages and tools use the OpenAI chat format
//   engine -> lai  {"think":"..."} / {"text":"..."}                  streamed deltas
//                  {"done":{"content":"..","tool_calls":[{"id","name","arguments"}]},
//                   "tokens":N,"tps":X}                             end of reply
//                  {"error":"..."}                                  request failed
// SIGINT stops the reply in progress; it then ends with "done" as usual.

#include "chat.h"
#include "common.h"
#include "json.h"
#include "llama.h"
#include "sampling.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <clocale>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <type_traits>
#include <vector>

static std::atomic<bool> g_stop{false};

static void on_sigint(int) { g_stop = true; }

static void send(const common_json & j) {
    std::string s = j.dump_safe();
    s += '\n';
    fwrite(s.data(), 1, s.size(), stdout);
    fflush(stdout);
}

static void send_error(const std::string & msg) { send(common_json{{"error", msg}}); }

// length of the longest prefix of s that does not end inside a UTF-8 sequence
static size_t utf8_complete(const std::string & s) {
    size_t n = s.size();
    for (size_t back = 1; back <= 4 && back <= n; back++) {
        unsigned char c = s[n - back];
        if ((c & 0xC0) == 0x80) {
            continue;  // continuation byte, keep looking for the lead byte
        }
        size_t len = (c & 0x80) == 0 ? 1 : (c & 0xE0) == 0xC0 ? 2 : (c & 0xF0) == 0xE0 ? 3 : 4;
        return back < len ? n - back : n;
    }
    return n;
}

// streams deltas, holding back bytes of a character split across tokens
struct delta_stream {
    std::string pending_text, pending_think;

    void push(const char * key, std::string & pending, const std::string & delta, bool flush) {
        pending += delta;
        size_t n = flush ? pending.size() : utf8_complete(pending);
        if (n > 0) {
            send(common_json{{key, pending.substr(0, n)}});
            pending.erase(0, n);
        }
    }
    void text(const std::string & d, bool flush = false) { push("text", pending_text, d, flush); }
    void think(const std::string & d, bool flush = false) { push("think", pending_think, d, flush); }
};

struct engine {
    llama_model *   model = nullptr;
    llama_context * ctx   = nullptr;
    const llama_vocab * vocab = nullptr;
    llama_batch_ext *   batch = nullptr;
    common_chat_templates_ptr tmpls;
    std::vector<llama_token>  cached;  // tokens currently in the KV cache
    int n_ctx   = 0;
    int n_batch = 0;

    // evaluate tokens at positions starting from cached.size(); logits for the last one
    bool eval(const std::vector<llama_token> & toks, size_t from) {
        for (size_t i = from; i < toks.size(); i += n_batch) {
            size_t n = std::min((size_t) n_batch, toks.size() - i);
            llama_batch_ext_clear(batch);
            for (size_t k = 0; k < n; k++) {
                int32_t idx = llama_batch_ext_add_token(batch, 0, toks[i + k]);
                llama_pos pos = (llama_pos) cached.size();
                llama_batch_ext_set_pos(batch, idx, &pos);
                cached.push_back(toks[i + k]);
            }
            if (i + n == toks.size()) {
                llama_batch_ext_set_output_logits(batch, (int32_t) n - 1, true);
            }
            if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch) != 0) {
                return false;
            }
            if (g_stop) {
                return false;
            }
        }
        return true;
    }

    std::vector<llama_token> tokenize(const common_chat_prompt & prompt) {
        std::vector<llama_token> out;
        bool first = true;
        for (const auto & part : prompt.parts) {
            // text from the user must not be able to inject special tokens
            auto t = common_tokenize(vocab, part.text, /* add_special */ first, /* parse_special */ !part.is_input);
            out.insert(out.end(), t.begin(), t.end());
            first = false;
        }
        return out;
    }

    void handle(const common_json & req) {
        common_chat_templates_inputs inputs;
        inputs.messages         = common_chat_msgs_parse_oaicompat(req.at("messages"));
        inputs.tools            = common_chat_tools_parse_oaicompat(req.value("tools", common_json()));
        inputs.use_jinja        = true;
        inputs.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
        inputs.add_generation_prompt = true;
        inputs.parallel_tool_calls   = true;
        // models that reason before answering (Qwen3.5...) can skip it for speed
        if (req.contains("thinking") && req.at("thinking").is_boolean()) {
            inputs.enable_thinking = req.at("thinking").get<bool>();
        }

        common_chat_session session(tmpls.get(), vocab, inputs);
        std::vector<llama_token> toks = tokenize(session.prompt());
        if ((int) toks.size() >= n_ctx) {
            send_error("the request exceeds the available context size (" + std::to_string(toks.size()) +
                       " tokens, context " + std::to_string(n_ctx) + ")");
            return;
        }

        // reuse the KV cache for the prefix shared with the previous request
        size_t keep = 0;
        while (keep < cached.size() && keep < toks.size() && cached[keep] == toks[keep]) {
            keep++;
        }
        if (keep == toks.size()) {
            keep--;  // re-evaluate the last token to get fresh logits
        }
        llama_memory_seq_rm(llama_get_memory(ctx), 0, (llama_pos) keep, -1);
        cached.resize(keep);

        common_params_sampling sp;
        auto num = [&](const char * key, auto & field) {
            if (req.contains(key) && req.at(key).is_number()) {
                field = (std::remove_reference_t<decltype(field)>) req.at(key).get<double>();
            }
        };
        num("temperature", sp.temp);
        num("top_p", sp.top_p);
        num("top_k", sp.top_k);
        num("min_p", sp.min_p);
        num("repeat_penalty", sp.penalty_repeat);
        int max_tokens = req.contains("max_tokens") && req.at("max_tokens").is_number()
                             ? (int) req.at("max_tokens").get<double>() : 0;
        session.apply_sampling(sp);
        common_sampler_ptr smpl(common_sampler_init(model, sp));
        if (!smpl) {
            send_error("failed to set up sampling (bad tool grammar?)");
            return;
        }
        for (auto t : toks) {
            common_sampler_accept(smpl.get(), t, false);
        }

        if (!eval(toks, keep)) {
            cached.resize(keep);
            llama_memory_seq_rm(llama_get_memory(ctx), 0, (llama_pos) keep, -1);
            if (g_stop) {
                send(common_json{{"done", common_json{{"content", ""}}}, {"tokens", 0}});
            } else {
                send_error("failed to evaluate the prompt");
            }
            return;
        }

        delta_stream out;
        common_chat_msg prev;
        prev.role = "assistant";
        std::string generated;
        const auto & stops = session.additional_stops();
        int n_gen = 0;
        auto t0 = std::chrono::steady_clock::now();

        auto emit = [&](const common_chat_msg & msg) {
            try {
                for (const auto & d : common_chat_msg_diff::compute_diffs(prev, msg)) {
                    if (!d.reasoning_content_delta.empty()) out.think(d.reasoning_content_delta);
                    if (!d.content_delta.empty()) out.text(d.content_delta);
                }
            } catch (const std::exception &) {
                // the parser revised earlier output; the final message is still sent in "done"
            }
            prev = msg;
        };

        while (!g_stop) {
            if ((int) cached.size() >= n_ctx || (max_tokens > 0 && n_gen >= max_tokens)) {
                break;
            }
            llama_token tok = common_sampler_sample(smpl.get(), ctx, -1);
            common_sampler_accept(smpl.get(), tok, true);
            if (llama_vocab_is_eog(vocab, tok)) {
                break;
            }
            n_gen++;
            std::string piece = common_token_to_piece(vocab, tok, true);
            generated += piece;
            common_chat_input chunk;
            chunk.append(piece, tok);
            try {
                emit(session.feed(chunk));
            } catch (const std::exception &) {
                // partial output the parser cannot read yet
            }
            bool stopped = false;
            for (const auto & s : stops) {
                if (!s.empty() && generated.size() >= s.size() &&
                    generated.compare(generated.size() - s.size(), s.size(), s) == 0) {
                    stopped = true;
                }
            }
            if (stopped || !eval({tok}, 0)) {
                break;
            }
        }

        common_chat_msg final_msg;
        try {
            final_msg = session.finish();
        } catch (const std::exception &) {
            final_msg = prev;
            if (final_msg.content.empty() && final_msg.tool_calls.empty()) {
                final_msg.content = generated;  // unparseable: hand back the raw text
            }
        }
        emit(final_msg);
        out.think("", true);
        out.text("", true);

        double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        common_json calls = common_json::array();
        for (const auto & tc : final_msg.tool_calls) {
            calls.push_back({{"id", tc.id}, {"name", tc.name}, {"arguments", tc.arguments}});
        }
        send(common_json{
            {"done", common_json{{"content", final_msg.content}, {"tool_calls", calls}}},
            {"tokens", n_gen},
            {"tps", secs > 0 ? n_gen / secs : 0.0},
        });
    }
};

static void usage(const char * argv0) {
    fprintf(stderr,
            "usage: %s -m model.gguf [-c ctx] [-ngl layers] [-t threads] [--kv f16|q8_0|q4_0] [--fa on|off|auto]\n"
            "          [--ubatch n] [--cpu-moe] [--kv-ram] [--kv-limit MB] [--repack]\n"
            "  -c 0 uses the model's full context; --kv-limit caps the context to fit the cache in MB\n",
            argv0);
}

// bytes of KV cache per token of context, from the model's attention shape
static double kv_bytes_per_token(const llama_model * model, ggml_type kv) {
    char arch[64] = {0};
    llama_model_meta_val_str(model, "general.architecture", arch, sizeof(arch));
    auto meta_int = [&](const char * suffix) -> long {
        char buf[64];
        std::string key = std::string(arch) + suffix;
        if (llama_model_meta_val_str(model, key.c_str(), buf, sizeof(buf)) < 0) {
            return -1;
        }
        return strtol(buf, nullptr, 10);
    };
    long n_head = llama_model_n_head(model);
    long k_len  = meta_int(".attention.key_length");
    long v_len  = meta_int(".attention.value_length");
    if (k_len <= 0) {
        k_len = n_head > 0 ? llama_model_n_embd(model) / n_head : 128;
    }
    if (v_len <= 0) {
        v_len = k_len;
    }
    // hybrid models (e.g. Qwen3.5) keep a KV cache only in their full-attention
    // layers, one in every <interval>; the others hold a small fixed state
    long n_attn = llama_model_n_layer(model);
    long interval = meta_int(".full_attention_interval");
    if (llama_model_is_hybrid(model) && interval > 1) {
        n_attn = (n_attn + interval - 1) / interval;
    }
    return (double) n_attn * llama_model_n_head_kv(model) * (k_len + v_len) * ((double) ggml_type_size(kv) / ggml_blck_size(kv));
}

static bool kv_type(const std::string & s, ggml_type & out) {
    if (s == "f16")  { out = GGML_TYPE_F16;  return true; }
    if (s == "q8_0") { out = GGML_TYPE_Q8_0; return true; }
    if (s == "q4_0") { out = GGML_TYPE_Q4_0; return true; }
    return false;
}

int main(int argc, char ** argv) {
    std::setlocale(LC_NUMERIC, "C");
    std::signal(SIGINT, on_sigint);

    std::string model_path;
    int n_ctx = 8192, ngl = -999, threads = 0, ubatch = 512, kv_limit_mb = 0;
    bool repack = false, cpu_moe = false, kv_ram = false;
    ggml_type kv = GGML_TYPE_F16;
    std::string fa = "auto";
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) { usage(argv[0]); exit(2); }
            return argv[++i];
        };
        if (a == "-m") model_path = next();
        else if (a == "-c") n_ctx = std::stoi(next());
        else if (a == "-ngl") ngl = std::stoi(next());
        else if (a == "-t") threads = std::stoi(next());
        else if (a == "--kv") { if (!kv_type(next(), kv)) { usage(argv[0]); return 2; } }
        else if (a == "--fa") fa = next();
        else if (a == "--ubatch") ubatch = std::stoi(next());
        else if (a == "--repack") repack = true;
        else if (a == "--cpu-moe") cpu_moe = true;
        else if (a == "--kv-ram") kv_ram = true;
        else if (a == "--kv-limit") kv_limit_mb = std::stoi(next());
        else { usage(argv[0]); return 2; }
    }
    if (model_path.empty()) {
        usage(argv[0]);
        return 2;
    }

    // llama.cpp's own log goes to stderr, which lai sends to a log file
    llama_backend_init();

    // One working copy of each weight: map the file and compute straight from
    // it. llama.cpp's default repacking copies CPU weights into a second
    // layout in RAM, which doubles them when the file itself sits in RAM.
    llama_model_params mp = llama_model_default_params();
    mp.load_mode       = LLAMA_LOAD_MODE_MMAP;
    mp.use_extra_bufts = repack;
    if (ngl != -999) {
        mp.n_gpu_layers = ngl;
    }
    // MoE: keep the expert tensors (most of the file) in mapped RAM and put
    // everything else, plus the KV cache, on the GPU.
    std::vector<llama_model_tensor_buft_override> overrides;
    if (cpu_moe) {
        overrides.push_back(llm_ffn_exps_cpu_override());
        overrides.push_back({nullptr, nullptr});
        mp.tensor_buft_overrides = overrides.data();
    }
    engine e;
    e.model = llama_model_load_from_file(model_path.c_str(), mp);
    if (!e.model) {
        send_error("failed to load model " + model_path);
        return 1;
    }
    e.vocab = llama_model_get_vocab(e.model);

    // context length: what was asked for, at most what the model was trained
    // on, and at most what fits in the KV budget
    const int n_train = llama_model_n_ctx_train(e.model);
    if (n_ctx <= 0 || (n_train > 0 && n_ctx > n_train)) {
        n_ctx = n_train > 0 ? n_train : 8192;
    }
    const double per_token = kv_bytes_per_token(e.model, kv);
    if (kv_limit_mb > 0) {
        int fit = (int) ((double) kv_limit_mb * 1024 * 1024 / per_token) / 256 * 256;
        if (fit < 512) {
            send_error("kv_limit_mb " + std::to_string(kv_limit_mb) + " MB is too small: this model needs " +
                       std::to_string((int) (per_token * 512 / (1024 * 1024)) + 1) + " MB for even 512 tokens");
            return 1;
        }
        n_ctx = std::min(n_ctx, fit);
    }
    fprintf(stderr, "lai-engine: context %d tokens, KV cache about %.0f MiB (%s)\n", n_ctx,
            per_token * n_ctx / (1024 * 1024), kv_ram ? "RAM" : "GPU if available");

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = n_ctx;
    // the compute buffer grows with the micro-batch; prompts are fed in chunks of this size
    cp.n_batch  = ubatch;
    cp.n_ubatch = ubatch;
    cp.type_k  = kv;
    cp.type_v  = kv;
    // KV cache in system RAM instead of VRAM: far more room for context on a
    // small GPU, at the cost of running attention on the CPU
    cp.offload_kqv = !kv_ram;
    cp.flash_attn_type = fa == "on" ? LLAMA_FLASH_ATTN_TYPE_ENABLED
                       : fa == "off" ? LLAMA_FLASH_ATTN_TYPE_DISABLED
                                     : LLAMA_FLASH_ATTN_TYPE_AUTO;
    int nt = threads > 0 ? threads : common_cpu_get_num_math();
    cp.n_threads = cp.n_threads_batch = nt;
    e.ctx = llama_init_from_model(e.model, cp);
    if (!e.ctx) {
        send_error("failed to create the context (try a smaller -c or --kv q8_0)");
        return 1;
    }
    e.n_ctx   = (int) llama_n_ctx(e.ctx);
    e.n_batch = (int) llama_n_batch(e.ctx);
    e.batch   = llama_batch_ext_init(e.ctx);

    try {
        e.tmpls = common_chat_templates_init(e.model, "");
    } catch (const std::exception & ex) {
        send_error(std::string("chat template: ") + ex.what());
        return 1;
    }

    send(common_json{{"ready", true}, {"ctx", e.n_ctx}, {"kv_mb", (int) (per_token * e.n_ctx / (1024 * 1024))}});

    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) {
            continue;
        }
        g_stop = false;
        try {
            e.handle(common_json::parse(line));
        } catch (const std::exception & ex) {
            send_error(ex.what());
        }
    }

    llama_batch_ext_free(e.batch);
    llama_free(e.ctx);
    llama_model_free(e.model);
    return 0;
}
