FROM registry.fedoraproject.org/fedora-minimal:42
# Based on https://github.com/bsudy/saml-proxy of barnabas.sudy@gmail.com
LABEL maintainer="Priit Randla <priit.randla@entigo.com>"

RUN microdnf update --nodocs -y \
  && microdnf install --nodocs -y \
    procps-ng \
    iproute \
    apr-util-openssl \
    httpd \
    mod_auth_gssapi \
    mod_auth_mellon \
    mod_intercept_form_submit \
    mod_session \
    mod_ssl \
    gettext \
    sscg \
  && microdnf clean all && rm -rf /var/cache/dnf

# Fix permissions for non-root operation

RUN sed -i '/^Listen 80$/d' /etc/httpd/conf/httpd.conf \
  && sed -i 's|/etc/pki/tls/certs/localhost.crt|/etc/httpd/tls/certs/localhost.crt|g' /etc/httpd/conf.d/ssl.conf \
  && sed -i 's|/etc/pki/tls/private/localhost.key|/etc/httpd/tls/private/localhost.key|g' /etc/httpd/conf.d/ssl.conf \
  && sed -i 's/^Listen 443/Listen 8443/' /etc/httpd/conf.d/ssl.conf \
  && sed -i 's/_default_:443/_default_:8443/' /etc/httpd/conf.d/ssl.conf \
  && mkdir -p /run/httpd /etc/httpd/tls/certs /etc/httpd/tls/private \
  && chown -R apache:0 /run/httpd \
  && chown -R apache:0 /var/log/httpd \
  && chown -R apache:0 /etc/httpd/conf.d \
  && chown -R apache:0 /etc/httpd/tls \
  && chmod -R g+rwX /run/httpd \
  && chmod -R g+rwX /var/log/httpd \
  && chmod -R g+rwX /etc/httpd/conf.d \
  && chmod -R g+rwX /etc/httpd/tls

# Add mod_auth_mellon setup script
COPY mellon_create_metadata.sh /usr/sbin/mellon_create_metadata.sh
# Add conf file for Apache
COPY proxy.conf /etc/httpd/conf.d/proxy.conf.template
COPY configure /usr/sbin/configure
RUN chmod +x /usr/sbin/configure /usr/sbin/mellon_create_metadata.sh

EXPOSE 8080 8443

# User apache id on Fedora
USER 48 

ENTRYPOINT ["/usr/sbin/configure"]
