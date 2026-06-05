FROM frappe/erpnext:version-16

USER root

# Install supervisor and nginx
RUN apt-get update && apt-get install -y supervisor nginx && rm -rf /var/lib/apt/lists/*

# Copy configuration files
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh

# Overwrite the base image's erpnext code with the local workspace code
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/erpnext

# Compile and build assets as frappe user
USER frappe
RUN cd /home/frappe/frappe-bench && \
    bench build --app erpnext

USER root
EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
