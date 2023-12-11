FROM registry.access.redhat.com/ubi9/nginx-120

# Install git, clone repo and prepare it to be served, uninstall git
# Taken from https://theartofmachinery.com/2016/07/02/git_over_http.html
USER 0
RUN dnf -y install git-core \
    && git --bare clone https://github.com/concaf/golang-docker-build-tutorial golang-docker-build-tutorial \
    && cd golang-docker-build-tutorial/.git \
    && git --bare update-server-info \
    && dnf -y remove git-core \
    && dnf clean all \
    && mv hooks/post-update.sample hooks/post-update \
    && cd ../../ \
    && chown -R 1001:0 ./golang-docker-build-tutorial
USER 1001

# Build with:
#    podman build -t build-image-nginx -f tests/scaling-pipelines/utils/build-image/Containerfile tests/scaling-pipelines/utils/build-image/
# Run with:
#    podman run --rm -ti -p 8080:8080 build-image-nginx
# Clone from it with:
#    git clone http://localhost:8080/golang-docker-build-tutorial/.git
CMD nginx -g "daemon off;"
