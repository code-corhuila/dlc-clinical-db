FROM liquibase/liquibase:4.31.1

RUN lpm add liquibase-mongodb mongodb --global

COPY changelog /liquibase/changelog
COPY 01_ddl /liquibase/01_ddl
COPY 02_dml /liquibase/02_dml
COPY 03_dcl /liquibase/03_dcl
