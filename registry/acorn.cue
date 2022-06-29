import "encoding/yaml"

args: {
	deploy: {
		//Cache backend for blobdescriptor default 'inmemory' you can also use redis
		storageCache: *"inmemory" | "redis"

		//Enable metrics endpoint
		enableMetrics: *true | false | bool

		//This is the username allowed to login and push items to the registry. Default is randomly generated and can be obtained from the secret"
		htpasswdUsername: *"" | string

		//This is the password to login and push items to the registry. Default is randomly generated and can be obtained from the secret"
		htpasswdPassword: *"" | string

		//Number of registry containers to run.
		scale: int | *1

		//Provide the complete storage configuration blob in registry config format.
		storageConfig: {}

		//Provide the complete auth configuration blob in registry config format.
		authConfig: {}

		//Provide additional configuration for the registry
		extraRegistryConfig: {}
	}
}

containers: {
	registry: {
		image:  "registry:2.8.1"
		scale:  args.deploy.scale
		expose: "5000:5000/http"
		if args.deploy.enableMetrics {
			ports: "5001:5001/http"
		}
		files: {
			"/auth/htpasswd":                  "secret://generated-htpasswd/content?onchange=no-action"
			"/etc/docker/registry/config.yml": "secret://registry-config/template?onchange=redeploy"
		}
		probes: ready: "http://localhost:5000"
	}
}

jobs: {
	"htpasswd-create": {
		env: {
			"USER": "secret://registry-user-creds/username"
			"PASS": "secret://registry-user-creds/password"
		}
		entrypoint: "/bin/sh -c"
		image:      "httpd:2"
		// Output of a generated secret needs to be placed in the file /run/secrets/output.
		cmd: ["htpasswd -Bbc /run/secrets/output $USER $PASS"]
	}
}

acorns: {
	if args.deploy.storageCache == "redis" {
		redis: {
			build: "../redis"
			ports: {
				"6379:6379/tcp"
			}
		}
	}
}

secrets: {
	"registry-user-creds": {
		type: "basic"
		data: {
			username: "\(args.deploy.htpasswdUsername)"
			password: "\(args.deploy.htpasswdPassword)"
		}
	}
	"generated-htpasswd": {
		type: "generated"
		params: {
			job: "htpasswd-create"
		}
	}
	"registry-config": {
		type: "template"
		data: {template: yaml.Marshal(localData.registryConfig)}
	}
	"registry-http-secret": type: "token"

	// Provides user a target to bind in secret data
	"user-secret-data": type: "opaque"
}

localData: {
	storageDriver: args.deploy.storageConfig
	if len(storageDriver) == 0 {
		storageDriver: filesystem: rootdirectory: "/var/lib/registry"
	}

	authConfig: args.deploy.authConfig
	if len(authConfig) == 0 {
		authConfig: htpasswd: {
			realm: "Registry Realm"
			path:  "/auth/htpasswd"
		}
	}

	registryConfig: args.deploy.extraRegistryConfig & {
		version: "0.1"
		log: fields: service:           "registry"
		storage: cache: blobdescriptor: args.deploy.storageCache
		storage: storageDriver
		auth:    authConfig
		http: {
			addr:   ":5000"
			secret: "${secret://registry-http-secret/token}"
			headers: {
				"X-Content-Type-Options": ["nosniff"]
			}
		}
		health: {
			storagedriver: {
				enabled:   true
				interval:  "10s"
				threshold: 3
			}
		}
	}

	if args.deploy.storageCache == "redis" {
		registryConfig: redis: {
			password:     string | *"${secret://redis.redis-auth/token}"
			addr:         "redis:6379"
			db:           0
			dialtimeout:  string | *"10ms"
			readtimeout:  string | *"10ms"
			writetimeout: string | *"10ms"
			pool: {
				maxidle:     int | *16
				maxactive:   int | *64
				idletimeout: string | *"300s"
			}
		}
	}

	if args.deploy.enableMetrics {
		registryConfig: metricsConfig: debug: {
			addr: "0.0.0.0:5001"
			prometheus: {
				enabled: true
				path:    "/metrics"
			}
		}
	}
}
