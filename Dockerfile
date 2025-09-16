FROM ubuntu:latest

RUN apt -qqq update

RUN apt -qqq install \
    cpanminus \
    libdatetime-perl \
    libdevel-confess-perl \
    libjson-xs-perl \
    liblwp-protocol-https-perl \
    libtest-exception-perl \
    libtext-csv-xs-perl \
    libxml-libxml-perl \
    libyaml-perl \
    gcc

RUN cpanm -qn Data::Mirror Object::Anon HTML5::DOM
