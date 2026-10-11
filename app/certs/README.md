# Certificates

`aws-rds-global-bundle.pem` holds the root certificates of every Amazon RDS region. With
`sslmode=verify-full`, the service uses it to check that it is talking to the real RDS
instance. AWS publishes it at
https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem. Its roots are valid
until 2061 or later; download it again when AWS adds a region or a new certificate authority.

Azure Database for PostgreSQL uses publicly trusted certificates, so Azure needs no bundle
here. On Google Cloud the Cloud SQL connector verifies the instance itself.
