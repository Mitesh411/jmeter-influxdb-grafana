FROM eclipse-temurin:21-jre

ARG JMETER_VERSION=5.6.3
# Official checksum from https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-5.6.3.tgz.sha512
ARG JMETER_SHA512=5978a1a35edb5a7d428e270564ff49d2b1b257a65e17a759d259a9283fc17093e522fe46f474a043864aea6910683486340706d745fcdf3db1505fd71e689083

ENV JMETER_HOME=/opt/apache-jmeter
ENV PATH="${JMETER_HOME}/bin:${PATH}"

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && curl -fsSL -o /tmp/jmeter.tgz "https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz" \
 && echo "${JMETER_SHA512}  /tmp/jmeter.tgz" | sha512sum -c - \
 && tar -xzf /tmp/jmeter.tgz -C /opt \
 && mv "/opt/apache-jmeter-${JMETER_VERSION}" "${JMETER_HOME}" \
 && rm -f /tmp/jmeter.tgz \
 && rm -rf /var/lib/apt/lists/*

# curl stays installed: run-test.sh uses it to record runs in InfluxDB.
COPY --chmod=755 run-test.sh /usr/local/bin/run-test.sh

WORKDIR /tests
ENTRYPOINT ["run-test.sh"]
