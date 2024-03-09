FROM golang:alpine3.18 AS builder
WORKDIR /app
COPY . /app/
RUN go build -v -o cfporttest -trimpath -ldflags "-s -w -buildid=" ./

FROM nginx:alpine3.18
WORKDIR /app
COPY --from=builder /app/cfporttest ./
COPY nginx.conf /etc/nginx/nginx.conf
COPY cert/* ./cert/
RUN chmod +x cfporttest
CMD ./cfporttest & /usr/sbin/nginx -g "daemon off;"