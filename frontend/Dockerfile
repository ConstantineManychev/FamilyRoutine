FROM ghcr.io/cirruslabs/flutter:3.41.5 AS build

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .
RUN flutter build web --release --wasm --csp --no-web-resources-cdn \
 && find build/web -type f -regex '.*\.\(js\|mjs\|wasm\|json\|css\|html\|otf\|ttf\)' -exec gzip -9 -k {} +

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build/web /usr/share/nginx/html
