FROM liquibase/liquibase:4.31.1

RUN lpm add liquibase-mongodb mongodb --global

WORKDIR /workspace

COPY changelog /workspace/changelog
COPY 01_ddl /workspace/01_ddl
COPY 02_dml /workspace/02_dml
COPY 03_dcl /workspace/03_dcl
