This stuff installs [kubernetes-dashboard](https://github.com/kubernetes/dashboard).

This was built following the [Provision an EKS cluster](https://learn.hashicorp.com/terraform/kubernetes/provision-eks-cluster) guide.

To add SSL certs, follow [these instructions](https://github.com/kubernetes/dashboard/blob/master/docs/user/installation.md#recommended-setup)

Once it's built you can test it by running:
```bash
kubectl proxy
open http://127.0.0.1:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/
# or
open http://localhost:8001/api/v1/namespaces/kube-system/services/https:kubernetes-dashboard:/proxy/

```
