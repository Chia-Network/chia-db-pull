FROM alpine:latest

RUN apk add --no-cache aws-cli sqlite

COPY --chmod=+x entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
