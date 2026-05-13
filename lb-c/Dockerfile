FROM alpine:3.20 AS build
RUN apk add --no-cache build-base
WORKDIR /src
COPY lb-c/main.c ./main.c
RUN mkdir -p /out && cc -O3 -pipe -march=native -pthread -o /out/lb main.c

FROM alpine:3.20
COPY --from=build /out/lb /usr/local/bin/lb
EXPOSE 9999
CMD ["/usr/local/bin/lb"]
