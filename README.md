FROM kong

USER root
# Example for GO:
COPY kong-plugin-firebase-app-check /usr/local/bin/kong-plugin-firebase-app-check

USER kong
ENTRYPOINT ["/docker-entrypoint.sh"]
EXPOSE 8000 8443 8001 8444
STOPSIGNAL SIGQUIT
HEALTHCHECK --interval=10s --timeout=10s --retries=10 CMD kong health
CMD ["kong", "docker-start"]