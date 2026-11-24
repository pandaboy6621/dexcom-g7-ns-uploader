FROM alpine:3.20
RUN apk add --no-cache bash curl jq tzdata ca-certificates
COPY dexcom-ns-uploader.sh /usr/local/bin/dexcom-ns-uploader.sh
RUN chmod +x /usr/local/bin/dexcom-ns-uploader.sh
USER nobody
ENTRYPOINT ["/usr/local/bin/dexcom-ns-uploader.sh"]
