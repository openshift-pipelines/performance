kubectl -n utils create deployment build-image-nginx --image=quay.io/rhcloudperfscale/git-http-smart-hosting --replicas=1 --port=8000
kubectl -n utils expose deployment/build-image-nginx --port=80 --target-port=8080 --name=build-image-nginx
kubectl -n utils rollout status --watch --timeout=300s deployment/build-image-nginx
kubectl -n utils wait --for=condition=ready --timeout=300s pod -l app=build-image-nginx
