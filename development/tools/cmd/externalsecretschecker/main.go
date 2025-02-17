package main

import (
	"context"
	"encoding/json"
	"flag"
	"os"
	"strings"

	"github.com/pkg/errors"
	"github.com/sirupsen/logrus"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	_ "k8s.io/client-go/plugin/pkg/client/auth/gcp"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// ExternalSecretData stores data of one externalsecret key
type ExternalSecretData struct {
	Key      string `json:"key,omitempty"`
	Name     string `json:"name,omitempty"`
	Version  string `json:"version,omitempty"`
	Property string `json:"property,omitempty"`
	IsBinary bool   `json:"isBinary,omitempty"`
}

// ExternalSecretSpec stores data of externalsecret keys and used backend information
type ExternalSecretSpec struct {
	BackendType string
	Data        []ExternalSecretData
	ProjectID   string `json:"projectId"`
}

// ExternalSecret stores one ExternalSecret data
type ExternalSecret struct {
	APIVersion string `json:"apiVersion"`
	Kind       string
	Metadata   v1.ObjectMeta
	Spec       ExternalSecretSpec
	Status     v1.Status
}

// ExternalSecretsList stores list of external secrets returned by the REST API
type ExternalSecretsList struct {
	APIVersion string `json:"apiVersion"`
	Items      []ExternalSecret
	Kind       string
	Metadata   v1.ListMeta
}
type options struct {
	namespaces     string
	context        string
	ignoredSecrets string
	kubeconfig     string
}

func gatherOptions() options {
	o := options{}
	flag.StringVar(&o.namespaces, "namespaces", "", "Names of namespaces to check, separated by comma. If empty checks all.")
	flag.StringVar(&o.context, "context", "", "Name of the kubernetes context to use.")
	flag.StringVar(&o.ignoredSecrets, "ignored-secrets", "", "Names of ignored secrets in namespace/secretName format, separated by comma.")
	flag.StringVar(&o.kubeconfig, "kubeconfig", "", "Path to kubeconfig file.")
	flag.Parse()
	return o
}

func main() {
	o := gatherOptions()
	externalSecretsSuccesful := true
	secretsDeclaredAsExternal := true
	exitCode := 0

	var err error
	var config *rest.Config

	if o.kubeconfig != "" {
		config, err = buildConfigFromFlagsWithContext(o.context, o.kubeconfig)
		exitOnError(err, "while loading kubeconfig")
	} else {
		config, err = rest.InClusterConfig()
		exitOnError(err, "while loading in-cluster kubeconfig")
	}

	client, err := kubernetes.NewForConfig(config)
	exitOnError(err, "while creating kube client")

	namespaces, err := client.CoreV1().Namespaces().List(context.Background(), v1.ListOptions{})
	exitOnError(err, "while reading namespaces list")

	var checkedNamespaces []string
	if o.namespaces != "" {
		checkedNamespaces = strings.Split(o.namespaces, ",")
	}

	ignoredSecrets := parseIgnoredSecrets(o.ignoredSecrets)

	for _, namespace := range namespaces.Items {
		// check if we have defined list of namespaces to check, otherwise check all
		if len(checkedNamespaces) == 0 || nameInSlice(namespace.Name, checkedNamespaces) {
			// check status for all external secrets
			externalSecretsInNamespaceSuccesfull := checkExternalSecretsStatus(client, namespace.Name)
			if !externalSecretsInNamespaceSuccesfull {
				externalSecretsSuccesful = false
			}

			// check if all Opaque secrets are also declared as externalSecrets
			secretsInnamespaceDeclaredAsExternal := checkSecrets(client, namespace.Name, ignoredSecrets)
			if !secretsInnamespaceDeclaredAsExternal {
				secretsDeclaredAsExternal = false
			}
		}
	}

	if !externalSecretsSuccesful {
		logrus.Info("At least one ExternalSecret was not synchronized succesfully")
		exitCode++
	}

	if !secretsDeclaredAsExternal {
		logrus.Info("At least one secret was not declared as ExternalSecret")
		exitCode += 2
	}

	if exitCode == 0 {
		logrus.Info("No issues detected.")
	}

	os.Exit(exitCode)
}

func buildConfigFromFlagsWithContext(context, kubeconfigPath string) (*rest.Config, error) {
	return clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		&clientcmd.ClientConfigLoadingRules{ExplicitPath: kubeconfigPath},
		&clientcmd.ConfigOverrides{
			CurrentContext: context,
		}).ClientConfig()
}

func exitOnError(err error, context string) {
	if err != nil {
		logrus.Fatal(errors.Wrap(err, context))
	}
}

// nameInSlice checks if the string is in slice of strings
func nameInSlice(name string, slice []string) bool {
	for _, fragment := range slice {
		if name == fragment {
			return true
		}
	}
	return false
}

func parseIgnoredSecrets(ignoredSecretsString string) map[string][]string {
	ignoredSecrets := make(map[string][]string)
	if ignoredSecretsString != "" {
		ignoredSecretsSplit := strings.Split(ignoredSecretsString, ",")
		for _, ignored := range ignoredSecretsSplit {
			split := strings.Split(ignored, "/")

			ignoredSecrets[split[0]] = append(ignoredSecrets[split[0]], split[1])
		}
	}
	return ignoredSecrets
}

func getExternalSecretsList(client *kubernetes.Clientset, namespace string) ExternalSecretsList {
	externalSecretsJSON, err := client.RESTClient().Get().AbsPath("/apis/kubernetes-client.io/v1").Namespace(namespace).Resource("externalsecrets").DoRaw(context.Background())
	exitOnError(err, "while reading ExternalSecrets list")

	var externalSecretsList ExternalSecretsList
	err = json.Unmarshal(externalSecretsJSON, &externalSecretsList)
	exitOnError(err, "while unmarshalling ExternalSecrets list")
	return externalSecretsList
}

func checkExternalSecretsStatus(client *kubernetes.Clientset, namespace string) bool {
	success := true

	externalSecretsList := getExternalSecretsList(client, namespace)

	// check if ExternalSecrets synced successfully
	for _, externalSecret := range externalSecretsList.Items {
		if externalSecret.Status.Status != "SUCCESS" {
			logrus.Warnf("ExternalSecret \"%s\" in namespace \"%s\" failed to synchronize with status \"%s\"\n", externalSecret.Metadata.Name, namespace, externalSecret.Status.Status)
			success = false
		}
	}

	return success
}

func nameInExternals(secret string, externelSecrets ExternalSecretsList) bool {
	for _, externalSecret := range externelSecrets.Items {
		if secret == externalSecret.Metadata.Name {
			return true
		}
	}
	return false
}

func checkSecrets(client *kubernetes.Clientset, namespace string, ignoredSecrets map[string][]string) bool {
	allSecretsVerified := true
	externalSecretsList := getExternalSecretsList(client, namespace)

	secrets, err := client.CoreV1().Secrets(namespace).List(context.Background(), v1.ListOptions{})
	exitOnError(err, "while reading namespaces list")

	for _, sec := range secrets.Items {
		// get only user-created secrets
		if sec.Type == "Opaque" {
			// omit ignored ones
			if !nameInSlice(sec.Name, ignoredSecrets[namespace]) {
				if !nameInExternals(sec.Name, externalSecretsList) {
					logrus.Warnf("Secret \"%s\" in namespace \"%s\" was not declared as ExternalSecret\n", sec.Name, namespace)
					allSecretsVerified = false
				}
			}
		}
	}
	return allSecretsVerified
}
