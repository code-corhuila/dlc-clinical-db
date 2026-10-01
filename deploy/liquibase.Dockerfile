FROM liquibase/liquibase:4.31.1

RUN lpm add liquibase-mongodb mongodb --global
