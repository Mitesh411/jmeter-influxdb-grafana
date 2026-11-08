FROM jenkins/jenkins:2.580.2-lts-jdk21

# Docker CLI (+ buildx): the pipeline starts JMeter and sitespeed.io containers on the
# host's Docker engine through the mounted /var/run/docker.sock.
COPY --from=docker:29.9.2-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker:29.9.2-cli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt

# Configuration as code (casc.yaml) creates the admin user and the pipeline job.
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
