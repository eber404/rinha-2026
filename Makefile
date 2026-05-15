.PHONY: all preprocess lb api benchmark clean

all: preprocess lb api

preprocess:
	bash scripts/preprocess.sh

lb:
	mkdir -p load-balancer/build
	g++ -O3 -std=c++20 load-balancer/src/main.cpp -o load-balancer/build/lb

api:
	cd fraud-api && bun run build-native

benchmark:
	@cd .cache/rinha-official && ./run.sh

clean:
	rm -rf load-balancer/build/*
	rm -rf fraud-api/native/build/*
	rm -f scripts/preprocess scripts/reduce_dataset
	rm -rf vector-index/*.bin
