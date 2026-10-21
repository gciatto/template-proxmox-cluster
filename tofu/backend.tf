# All administrators must share one state with locking: configure a remote backend before
# adding resources, e.g. PostgreSQL (credentials from PG_CONN_STR in each admin's .env):
#
# terraform {
#   backend "pg" {}
# }
