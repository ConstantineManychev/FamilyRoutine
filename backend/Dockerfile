
FROM rust:1.76-alpine AS builder

RUN apk add --no-cache musl-dev

WORKDIR /app

COPY Cargo.toml Cargo.lock ./

RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release

COPY src ./src

RUN touch src/main.rs && cargo build --release

FROM alpine:latest

WORKDIR /app

COPY --from=builder /app/target/release/backend /app/backend

EXPOSE 3000

CMD ["./backend"]