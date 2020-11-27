FROM registry.fedoraproject.org/fedora-minimal:32
# Based on https://github.com/bsudy/saml-proxy of barnabas.sudy@gmail.com
MAINTAINER Priit Randla <priit.randla@entigo.com>

RUN microdnf install -y \
  apr-util-openssl \
  authconfig \
  httpd \
  mod_auth_gssapi \
  mod_auth_mellon \
  mod_intercept_form_submit \
  mod_session \
  mod_ssl \
  gettext \
  sscg \
  && microdnf clean all && rm -rf /var/cache/dnf

# Add mod_auth_mellon setup script
ADD mellon_create_metadata.sh /usr/sbin/mellon_create_metadata.sh

# Add conf file for Apache
ADD proxy.conf /etc/httpd/conf.d/proxy.conf.template

EXPOSE 80

ADD configure /usr/sbin/configure
ENTRYPOINT /usr/sbin/configure
