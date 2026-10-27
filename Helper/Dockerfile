FROM alpine:3.22 AS build
RUN apk add --no-cache build-base
WORKDIR /src
COPY . .
RUN cc -std=gnu17 -Os -static -Wall -Wextra -Werror -Wno-unused-function *.c vendor/sha256.c -lpthread -lm -o /outer-plaintext-helper && strip /outer-plaintext-helper
FROM scratch
COPY --from=build /outer-plaintext-helper /outer-plaintext-helper
