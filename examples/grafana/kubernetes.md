# Grafana in kubernetes

This is a very simple configuration how to use saml-proxy on front of Grafana when deployed to Kubernetes.

_Warn:_ When applying `GF_AUTH_PROXY_ENABLED` on grafana, make sure that it is not publicly accessible.

## Grafana configuration

I'm using the official Grafana image configured via environment variables.

### Deployment
```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: <<yournamespace>>
  labels:
    version: "3.1.1"
spec:
  strategy:
    rollingUpdate:
      maxSurge: 30%
      maxUnavailable: 30%
  progressDeadlineSeconds: 120
  revisionHistoryLimit: 5
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
        version: "3.1.1"
    spec:
      containers:
      - name: grafana
        image: "grafana/grafana:3.1.1"
        ports:
        - name: grafana
          containerPort: 3000
        env:
        # - name: GF_SERVER_ROOT_URL
        #   value: https://monitor.internal.beekeeper.io
        - name: GF_AUTH_PROXY_ENABLED
          value: "true"
        # The header name can be changed in saml proxy config
        - name: GF_AUTH_PROXY_HEADER_NAME
          value: X-Webauth-User
        - name: GF_AUTH_PROXY_HEADER_PROPERTY
          value: username
        - name: GF_AUTH_PROXY_AUTO_SIGN_UP
          value: "true"
        - name: GF_USERS_AUTO_ASSIGN_ORG
          value: "true"
        # The default privilege
        - name: GF_USERS_AUTO_ASSIGN_ORG_ROLE
          value: "Read Only Editor"
        - name: GF_USERS_ALLOW_ORG_CREATE
          value: 'false'
        - name: GF_USERS_ALLOW_SIGN_UP
          value: 'false'
    # VOLUME TO BE MOUNTED IF NEEDED
    #     volumeMounts:
    #     - name: grafana-storage
    #       mountPath: /var/lib/grafana
    #   volumes:
    #   - name: grafana-storage
    #     persistentVolumeClaim:
    #       claimName: grafana-storage
```

### Service

```
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: <<yournamespace>>
spec:
  ports:
    - name: http
      port: 80
      targetPort: grafana
  selector:
    app: grafana
```

## Saml proxy configuration

### ConfigMap

The configmap stores the SAML configuration. Download your IdP's SAML metadata and put it
into the config map (or use `kubectl create configmap --from-file`).

```
apiVersion: v1
kind: ConfigMap
metadata:
    name: saml-proxy-config
    namespace: <<yournamespace>>
data:
    saml_idp.xml: <EntityDescriptor>...</EntityDescriptor>

```

### Deployment

* I mount `saml_idp.xml` from the config as a volume.
* `EmailAddress` SAML field is mapped to `X-Webauth-User` header. In my config the Grafana usernames will be the email addresses from SAML IDP. You can change it to a field you want to use.

```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: saml-proxy
  namespace: <<yournamespace>>
  labels:
    version: "latest"
spec:
  strategy:
    rollingUpdate:
      maxSurge: 30%
      maxUnavailable: 30%
  progressDeadlineSeconds: 120
  revisionHistoryLimit: 5
  replicas: 1
  selector:
    matchLabels:
      app: saml-proxy
  template:
    metadata:
      labels:
        app: saml-proxy
        version: "latest"
    spec:
      containers:
      - name: saml-proxy
        image: "priitrent/saml-proxy:latest"
        ports:
        - name: http-service
          containerPort: 8080
        livenessProbe:
           tcpSocket:
             port: http-service
           initialDelaySeconds: 10
        # Mounting saml_idp.xml from configMap
        volumeMounts:
        - name: saml-volume
          mountPath: /etc/httpd/conf.d/saml_idp.xml
          subPath: saml_idp.xml
        env:
        - name: BACKEND
          value: "http://grafana"
        - name: REMOTE_USER_SAML_ATTRIBUTE
          value: login
        - name: SAML_MAP_EmailAddress
          value: X-WEBAUTH-USER
      volumes:
        - name: saml-volume
          configMap:
            name: saml-proxy-config
```

### Service

```
apiVersion: v1
kind: Service
metadata:
  name: saml-proxy
  namespace: <<yournamespace>>
spec:
  ports:
    - name: http
      port: 80
      targetPort: http-service
  selector:
    app: saml-proxy
```

## Ingress

```
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitor
  namespace: <<yournamespace>>
  annotations:
    # USE YOUR ANNOTATIONS
    # To enable let's encrypt with cert-manager: cert-manager.io/cluster-issuer: "letsencrypt"
spec:
  # The Ingress terminates TLS in front of the proxy.
  tls:
  - hosts:
    # The host where the service will be available
    - "grafana.example.com"
    secretName: grafana-tls
  rules:
  # The host where the service will be available
  - host: "grafana.example.com"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: saml-proxy
            port:
              name: http
```
