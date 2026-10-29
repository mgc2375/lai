FLAGS := -trimpath -ldflags="-s -w"
LLAMA_DIR ?= ../llama.cpp

lai: *.go
	CGO_ENABLED=0 go build $(FLAGS) -o lai .

# make engine LLAMA_DIR=/path/to/llama.cpp   (checkout of tag b11982)
engine: engine/lai-engine.cpp engine/CMakeLists.txt
	cmake -S engine -B build -DLLAMA_DIR=$(abspath $(LLAMA_DIR)) -DCMAKE_BUILD_TYPE=Release
	cmake --build build --target lai-engine -j
	cp build/lai-engine .

dist: *.go
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build $(FLAGS) -o dist/lai-linux-amd64 .
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build $(FLAGS) -o dist/lai-linux-arm64 .

install:
	./install.sh

.PHONY: engine dist install
