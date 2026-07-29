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
    libcrypt-dev \
    libc6-dev \
    gcc

RUN cpanm -qn Data::Mirror Object::Anon

RUN cpanm -vn HTML5::DOM
