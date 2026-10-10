FROM buildpack-deps:bookworm AS build

ARG FLUTTER_VERSION=3.47.7

RUN curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
  | tar -xJ -C /opt \
 && git config --global --add safe.directory /opt/flutter

ENV PATH=/opt/flutter/bin:$PATH
RUN flutter config --no-analytics && flutter precache --web

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get --enforce-lockfile

COPY . .
RUN flutter build web --release --wasm --csp --no-web-resources-cdn \
 && find build/web -type f -regex '.*\.\(js\|mjs\|wasm\|json\|css\|html\|otf\|ttf\)' -exec gzip -9 -k {} +

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build/web /usr/share/nginx/html
