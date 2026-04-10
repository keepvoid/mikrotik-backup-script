
FROM alpine:latest

RUN apk add --no-cache git openssh-client tzdata
RUN mkdir -p /backup /root/.ssh && chmod 700 /root/.ssh
COPY mikrotik-backup.sh .
RUN chmod +x /mikrotik-backup.sh
CMD ["/mikrotik-backup.sh"]