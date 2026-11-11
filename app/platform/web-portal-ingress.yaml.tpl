# BankObs frontend (web-portal) via Traefik. external-dns creates bankobs.${DOMAIN}
# in the public zone; TLS is terminated at the Traefik NLB (ACM). ${DOMAIN} is
# substituted at deploy time (make frontend DOMAIN=lab.example.com).
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: bankobs-frontend
  namespace: bankobs
spec:
  ingressClassName: traefik
  rules:
    - host: "bankobs.${DOMAIN}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-portal
                port:
                  number: 8200
