.PHONY: all preprocess lb api test-native test-api benchmark clean

all: preprocess lb api

preprocess:
	bash scripts/preprocess.sh

lb:
	mkdir -p load-balancer/build
	g++ -O3 -std=c++20 load-balancer/src/main.cpp -o load-balancer/build/lb

api:
	cd fraud-api && bun run build-native

test-native:
	mkdir -p /tmp
	g++ -O2 -std=c++20 fraud-api/native/tests/engine_smoke.cpp fraud-api/native/knn.cpp fraud-api/native/binding.cpp -o /tmp/engine_smoke
	/tmp/engine_smoke

test-api:
	cd fraud-api && bun test src/vectorize.test.ts

benchmark:
	@cd .cache/rinha-official && ./run.sh

clean:
	rm -rf load-balancer/build/*
	rm -rf fraud-api/native/build/*
	rm -f scripts/preprocess scripts/reduce_dataset
	rm -rf vector-index/*.bin
