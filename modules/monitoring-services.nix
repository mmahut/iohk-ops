{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.monitoring-services;
in {

  options = {
    services.monitoring-services = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Enable prometheus, alertmangaer, grafana and graylog.
        '';
      };

      applicationRules = mkOption {
        type = types.listOf types.attrs;
        default = [];
        description = ''
          Application specific alerting rules.
        '';
      };

      applicationDashboards = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Application specific dashboards.
        '';
      };

      grafanaCreds = mkOption {
        type = types.attrs;
        default = null;
        description = ''
          Name and password of the default administator user in grafana.
        '';
      };

      graylogCreds = mkOption {
        type = types.attrs;
        default = null;
        description = ''
          Name and password of the default administator user in graylog.
        '';
      };

      monitoredNodes = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Nodes to be monitored.
        '';
      };

      nginxMonitoredNodes = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Nodes running nginx to be monitored.
        '';
      };

      webhost = mkOption {
        type = types.str;
        description = ''
          Public web host used for prometheus, grafana, alertmanager and graylog.
        '';
        example = "monitoring.lan";
      };


      oauth = mkOption {
        type = types.submodule {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Enable OAuth authication for all monitoring services.
              '';
            };
            provider = mkOption {
              type = types.enum [
                "google"
                "github"
                "azure"
                "gitlab"
                "linkedin"
                "myusa"
              ];
              default = "google";
              description = ''
                OAuth provider.
              '';
            };
            emailDomain = mkOption {
              type = types.str;
              description = ''
                Email domain.
              '';
              example = "iohk.io";
            };
            clientID = mkOption {
              type = types.str;
              description = ''
                The OAuth Client ID.
              '';
              example = "123456.apps.googleusercontent.com";
            };
            clientSecret = mkOption {
              type = types.str;
              description = ''
                The OAuth Client Secret.
              '';
            };
            cookie.secret = mkOption {
              type = types.str;
              description = ''
                The seed string for secure cookies.
              '';
            };
          };
        };
        description = ''
          OAuth proxy configuration.
        '';
      };

      pagerDuty.serviceKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The seed string for secure cookies.
        '';
      };

      deadMansSnitch.pingUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The url that alertmanager should ping regularly to signal it is alive.
        '';
      };
    };
  };
  config = mkIf cfg.enable (mkMerge [
    (lib.mkIf cfg.oauth.enable {
      services = {
        oauth2_proxy = {
          enable = true;
          inherit (cfg.oauth) clientID clientSecret cookie provider;
          email.domains = [ "${cfg.oauth.emailDomain}" ];
          nginx.virtualHosts = [ "${cfg.webhost}" ];
        };
        nginx.virtualHosts."${cfg.webhost}".locations."/".extraConfig = ''
          return 301 https://${cfg.webhost}/graylog/;
        '';
      };
    })
    {
      # The following Graylog warning matches a similar Grafana auto-generated warning
      warnings = [ "Graylog passwords will be stored as plaintext in the Nix store!" ];
      environment.systemPackages = with pkgs; [ curl gnugrep jq ];
      networking.firewall.allowedTCPPorts = [ 80 443 5044 ];
      services = let
        oauthProxyConfig = if (cfg.oauth.enable) then ''
          auth_request /oauth2/auth;
          error_page 401 = /oauth2/sign_in;

          # pass information via X-User and X-Email headers to backend,
          # requires running with --set-xauthrequest flag
          auth_request_set $user   $upstream_http_x_auth_request_user;
          auth_request_set $email  $upstream_http_x_auth_request_email;
          proxy_set_header X-User  $user;
          proxy_set_header X-Email $email;

          # if you enabled --cookie-refresh, this is needed for it to work with auth_request
          auth_request_set $auth_cookie $upstream_http_set_cookie;
          add_header Set-Cookie $auth_cookie;
        '' else "";
      in {
        nginx = {
          enable = true;
          virtualHosts = {
            "${cfg.webhost}" = {
              enableACME = true;
              forceSSL = true;
              locations = {
                "/grafana/".extraConfig = ''
                  ${oauthProxyConfig}
                  proxy_pass http://localhost:3000/;
                  proxy_set_header Host $http_host;
                  proxy_set_header REMOTE_ADDR $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto https;
                '';
                "/prometheus/".extraConfig = ''
                  ${oauthProxyConfig}
                  proxy_pass http://localhost:9090/prometheus/;
                  proxy_set_header Host $http_host;
                  proxy_set_header REMOTE_ADDR $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto https;
                '';
                "/alertmanager/".extraConfig = ''
                  ${oauthProxyConfig}
                  proxy_pass http://localhost:9093/;
                  proxy_set_header Host $http_host;
                  proxy_set_header REMOTE_ADDR $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto https;
                '';
                "/graylog/".extraConfig = ''
                  ${oauthProxyConfig}
                  proxy_set_header Host $http_host;
                  proxy_set_header REMOTE_ADDR $remote_addr;
                  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                  proxy_set_header X-Forwarded-Proto https;
                  proxy_set_header X-Graylog-Server-URL https://${cfg.webhost}/graylog;
                  proxy_set_header X-Forward-Host $host;
                  proxy_set_header X-Forwarded-Server $host;

                  # Required to partially fix the API Browser, but also breaks the streaming page
                  # rewrite ^ $request_uri;
                  rewrite ^/graylog/(.*)$ /$1 break;
                  # return 400;                                   # https://stackoverflow.com/q/28684300
                  proxy_pass http://localhost:9000/;
                '';
              };
            };
          };
        };
        graylog = {
          enable = true;
          nodeIdFile = "/var/lib/graylog/node-id";
          passwordSecret = (
            if cfg.graylogCreds ? clusterSecret then
              cfg.graylogCreds.clusterSecret
            else
              builtins.trace ''
                ***********************************************************************************
                ******
                ******
                ******
                ****** GRAYLOG CLUSTER SECRET NEEDED
                ******
                ******
                ****** REQUIREMENT: To enable a monitoring deployment which includes Graylog,
                ******              a cluster specific pepper secret must be declared.
                ******
                ****** ACTION:      Create a clusterSecret string attribute in the static
                ******              graylog credentials file.
                ******
                ****** COMMAND:     The following example command generates such a string:
                ******
                ******
                ******              tr -cd '[:alnum:]' < /dev/urandom | head -c 96
                ******
                ******
                ******
              '' (abort "Graylog cluster secret required")
          );
          rootUsername = traceValFn (x:
            if x == "changeme" then ''
              *
              **********************************************************************
              WARNING: The graylog default administrative user name is "${x}".
                       Please customize this in the static graylog credentials file.
              **********************************************************************
            '' else ''
                Graylog custom administrative user name declared'')
            cfg.graylogCreds.user;
          rootPasswordSha2 = (
            if cfg.graylogCreds ? passwordHash then
              cfg.graylogCreds.passwordHash
            else
              builtins.trace ''
                ***********************************************************************************
                ******
                ******
                ******
                ****** GRAYLOG PASSWORD HASH NEEDED
                ******
                ******
                ****** REQUIREMENT: To enable a monitoring deployment which includes Graylog,
                ******              an administrative user SHA256 password hash created from
                ******              the plaintext password must be provided.
                ******
                ****** ACTION:      Create a passwordHash string attribute in the static
                ******              graylog credentials file by hashing the administrative user's
                ******              plaintext password as input.
                ******
                ****** COMMAND:     The following example command generates such a string, where
                ******              <password> is the plaintext password string of the administrative
                ******              user, also defined in the static graylog credentials file:
                ******
                ******              echo -n <password> | shasum -a 256 | sed -z 's/  -\n//g'
                ******
                ******
                ******
              '' (abort "Graylog password hash required")
          );
          elasticsearchHosts = [ "http://localhost:9200" ];
        # Elasticsearch config below is for a single node deployment
          extraConfig = ''
            http_bind_address = 0.0.0.0:9000
            elasticsearch_shards = 1
            elasticsearch_replicas = 0
          '';
        };
        elasticsearch = {
          enable = true;
          package = pkgs.elasticsearch6-oss;
        # Prevent graylog deflector indexing by turning off auto create index option
          extraConf = ''
            action.auto_create_index: false
          '';
        };
        mongodb = {
          enable = true;
        };
        grafana = {
          enable = true;
          users.allowSignUp = false;
          addr = "";
          domain = "${cfg.webhost}";
          rootUrl = "%(protocol)ss://%(domain)s/grafana/";
          extraOptions = lib.mkIf cfg.oauth.enable {
            AUTH_GOOGLE_ENABLED = "true";
            AUTH_GOOGLE_CLIENT_ID = cfg.oauth.clientID;
            AUTH_GOOGLE_CLIENT_SECRET = cfg.oauth.clientSecret;
          };
          provision = {
            enable = true;
            datasources = [
              {
                type = "prometheus";
                name = "prometheus";
                url = "http://localhost:9090/prometheus";
              }
            ];
            dashboards = [
              {
                name = "generic";
                options.path = ./grafana/generic;
              }] ++ (if (cfg.applicationDashboards != null) then [
              {
                name = "application";
                options.path = cfg.applicationDashboards;
              }] else []);
          };
          security = {
            adminPassword = traceValFn (x:
              if x == "changeme" then ''
                *
                **********************************************************************
                WARNING: The grafana default administrative password is "${x}".
                         Please customize this in the static grafana credentials file.
                **********************************************************************
              '' else ''
                Grafana custom administrative password declared'')
              cfg.grafanaCreds.password;
            adminUser = traceValFn (x:
              if x == "changeme" then ''
                *
                **********************************************************************
                WARNING: The grafana default administative user name is "${x}".
                         Please customize this in the static grafana credentials file.
                **********************************************************************
              '' else ''
                Grafana custom administrative user name declared'')
              cfg.grafanaCreds.user;
          };
        };
        prometheus.exporters = {
          blackbox = {
            enable = true;
            configFile = pkgs.writeText "blackbox-exporter.yaml" (builtins.toJSON {
              modules = {
                https_2xx = {
                  prober = "http";
                  timeout = "5s";
                  http = {
                    fail_if_not_ssl = true;
                  };
                };
                htts_2xx = {
                  prober = "http";
                  timeout = "5s";
                };
                ssh_banner = {
                  prober = "tcp";
                  timeout = "10s";
                  tcp = {
                    query_response = [ { expect = "^SSH-2.0-"; } ];
                  };
                };
                tcp_v4 = {
                  prober = "tcp";
                  timeout = "5s";
                  tcp = {
                    preferred_ip_protocol = "ip4";
                  };
                };
                tcp_v6 = {
                  prober = "tcp";
                  timeout = "5s";
                  tcp = {
                    preferred_ip_protocol = "ip6";
                  };
                };
                icmp_v4 = {
                  prober = "icmp";
                  timeout = "60s";
                  icmp = {
                    preferred_ip_protocol = "ip4";
                  };
                };
                icmp_v6 = {
                  prober = "icmp";
                  timeout = "5s";
                  icmp = {
                    preferred_ip_protocol = "ip6";
                  };
                };
              };
            });
          };
        };
        prometheus.alertmanager = {
          enable = cfg.pagerDuty.serviceKey != null;
          configuration = {
            route = {
              group_by = [ "alertname" "alias" ];
              group_wait = "30s";
              group_interval = "2m";
              receiver = "team-pager";
              routes = [
                {
                  match = {
                    severity = "page";
                  };
                  receiver = "team-pager";
                }
              ] ++ (if (cfg.deadMansSnitch.pingUrl != null) then [{
                  match = {
                    alertname = "DeadMansSnitch";
                  };
                  repeat_interval = "5m";
                  receiver = "deadmanssnitch";
                }] else []);
            };
            receivers = [
              {
                name = "team-pager";
                pagerduty_configs = [
                  {
                    service_key = cfg.pagerDuty.serviceKey;
                  }
                ];
              }
              ] ++ (if (cfg.deadMansSnitch.pingUrl != null) then [
              {
                name = "deadmanssnitch";
                webhook_configs = [{
                  send_resolved = false;
                  url = cfg.deadMansSnitch.pingUrl;
                }];
              }
            ] else []);
          };
        };
        prometheus2 = {
          enable = true;
          webExternalUrl = "https://${cfg.webhost}/prometheus/";
          extraFlags = [
            "--storage.tsdb.retention=8760h"
          ];

          alertmanagerURL = [ "localhost:9093" ];
          rules = [ (builtins.toJSON {
              groups = [
                {
                  name = "alerting-pipeline";
                  rules = [
                    {
                      alert = "DeadMansSnitch";
                      expr = "vector(1)";
                      labels = {
                        severity = "critical";
                      };
                      annotations = {
                        summary = "Alerting DeadMansSnitch.";
                        description = "This is a DeadMansSnitch meant to ensure that the entire Alerting pipeline is functional.";
                      };
                    }
                  ];
                }
                {
                  name = "system";
                  rules = [
                    {
                      alert = "node_down";
                      expr = "up == 0";
                      for = "5m";
                      labels = {
                        severity = "page";
                      };
                      annotations = {
                        summary = "{{$labels.alias}}: Node is down.";
                        description = "{{$labels.alias}} has been down for more than 5 minutes.";
                      };
                    }
                    {
                      alert = "node_systemd_service_failed";
                      expr = "node_systemd_unit_state{state=\"failed\"} == 1";
                      for = "4m";
                      labels = {
                        severity = "page";
                      };
                      annotations = {
                        summary = "{{$labels.alias}}: Service {{$labels.name}} failed to start.";
                        description = "{{$labels.alias}} failed to (re)start service {{$labels.name}}.";
                      };
                    }
                    {
                      alert = "node_filesystem_full_90percent";
                      expr = "sort(node_filesystem_free_bytes{device!=\"ramfs\"} < node_filesystem_size_bytes{device!=\"ramfs\"} * 0.1) / 1024^3";
                      for = "5m";
                      labels = {
                        severity = "page";
                      };
                      annotations = {
                        summary = "{{$labels.alias}}: Filesystem is running out of space soon.";
                        description = "{{$labels.alias}} device {{$labels.device}} on {{$labels.mountpoint}} got less than 10% space left on its filesystem.";
                      };
                    }
                    {
                      alert = "node_filesystem_full_in_4h";
                      expr = "predict_linear(node_filesystem_free_bytes{device!=\"ramfs\"}[1h], 4*3600) <= 0";
                      for = "5m";
                      labels = {
                        severity = "page";
                      };
                      annotations = {
                        summary = "{{$labels.alias}}: Filesystem is running out of space in 4 hours.";
                        description = "{{$labels.alias}} device {{$labels.device}} on {{$labels.mountpoint}} is running out of space of in approx. 4 hours";
                      };
                    }
                    {
                      alert = "node_filedescriptors_full_in_3h";
                      expr = "predict_linear(node_filefd_allocated[1h], 3*3600) >= node_filefd_maximum";
                      for = "20m";
                      labels = {
                        severity = "page";
                      };
                      annotations = {
                        summary = "{{$labels.alias}} is running out of available file descriptors in 3 hours.";
                        description = "{{$labels.alias}} is running out of available file descriptors in approx. 3 hours";
                      };
                    }
                    {
                      alert = "node_load1_90percent";
                      expr = "node_load1 / on(alias) count(node_cpu_seconds_total{mode=\"system\"}) by (alias) >= 0.9";
                      for = "1h";
                      labels = {
                        severity = "page";
                      };
                      annotations = {
                        summary = "{{$labels.alias}}: Running on high load.";
                        description = "{{$labels.alias}} is running with > 90% total load for at least 1h.";
                      };
                    }
                    {
                      alert = "node_cpu_util_90percent";
                      expr = "100 - (avg by (alias) (irate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) >= 90";
                      for = "1h";
                      labels = {
                        severity = "page";
                      };
                      annotations = {
                        summary = "{{$labels.alias}}: High CPU utilization.";
                        description = "{{$labels.alias}} has total CPU utilization over 90% for at least 1h.";
                      };
                    }
                    {
                      alert = "node_ram_using_99percent";
                      expr = "node_memory_MemFree_bytes + node_memory_Buffers_bytes + node_memory_Cached_bytes < node_memory_MemTotal_bytes * 0.01";
                      for = "30m";
                      labels = {
                        severity = "page";
                      };
                      annotations = {
                        summary = "{{$labels.alias}}: Using lots of RAM.";
                        description = "{{$labels.alias}} is using at least 90% of its RAM for at least 30 minutes now.";
                      };
                    }
                    {
                      alert = "node_swap_using_80percent";
                      expr = "node_memory_SwapTotal_bytes - (node_memory_SwapFree_bytes + node_memory_SwapCached_bytes) > node_memory_SwapTotal_bytes * 0.8";
                      for = "10m";
                      labels = {
                        severity = "page";
                      };
                      annotations = {
                        summary = "{{$labels.alias}}: Running out of swap soon.";
                        description = "{{$labels.alias}} is using 80% of its swap space for at least 10 minutes now.";
                      };
                    }
                    {
                      alert = "node_time_unsync";
                      expr = "abs(node_timex_offset_seconds) > 0.050 or node_timex_sync_status != 1";
                      for = "1m";
                      labels = {
                        severity = "page";
                      };
                      annotations = {
                        summary = "{{$labels.alias}}: Clock out of sync with NTP";
                        description = "{{$labels.alias}} Local clock offset is too large or out of sync with NTP";
                      };
                    }
                    {
                      alert = "http_high_internal_error_rate";
                      expr = "rate(nginx_vts_server_requests_total{code=\"5xx\"}[5m]) * 50 > on(alias, host) rate(nginx_vts_server_requests_total{code=\"2xx\"}[5m])";
                      for = "15m";
                      labels = {
                        severity = "page";
                      };
                      annotations = {
                        summary = "{{$labels.alias}}: High http internal error (code 5xx) rate";
                        description = "{{$labels.alias}}  number of correctly served requests is less than 50 times the number of requests aborted due to an internal server error";
                      };
                    }
                  ];
                }
                {
                  name = "application";
                  rules = cfg.applicationRules;
                }
              ];
            })];
          scrapeConfigs = [
            {
              job_name = "prometheus";
              scrape_interval = "5s";
              metrics_path = "/prometheus/metrics";
              static_configs = [
                {
                  targets = [
                    "localhost:9090"
                  ];
                  labels = { alias = "prometheus"; };
                }
              ];
            }
            {
              job_name = "node";
              scrape_interval = "10s";
              static_configs = let
                makeNodeConfig = nodeHostName: {
                  targets = [ "${nodeHostName}:9100" "${nodeHostName}:9102" ];
                  labels = { alias = nodeHostName; };
                };
              in map makeNodeConfig (cfg.monitoredNodes ++ cfg.nginxMonitoredNodes);
            }
            {
              job_name = "nginx";
              scrape_interval = "5s";
              metrics_path = "/status/format/prometheus";
              static_configs =  let
                makeNodeConfig = nodeHostName: {
                  targets = [ "${nodeHostName}:9113" ];
                  labels = { alias = nodeHostName; };
                };
              in map makeNodeConfig cfg.nginxMonitoredNodes;
            }
          ];
        };
      };
      systemd.services.graylog-preload = let
        graylogConfig = ./graylog/graylogConfig.json;
        password = traceValFn (x:
          if x == "changeme" then ''
            *
            **********************************************************************
            WARNING: The graylog default administrative password is "${x}".
                     Please customize this in the static graylog credentials file.
            **********************************************************************
          '' else ''
            Graylog custom administrative password declared'')
          cfg.graylogCreds.password;
        graylogPreload = pkgs.writeShellScriptBin "graylogPreload.sh" (readFile (
          pkgs.substituteAll {
            src = ./graylog/graylogPreload.sh;
            inherit (cfg.graylogCreds) user;
            inherit password;
          })
        );
      in lib.mkIf config.services.graylog.enable {
        description = "Graylog Content Pack Preload Service";
        wantedBy = [ "multi-user.target" ];
        after = [ "graylog.service elasticsearch.service mongodb.service" ];
        path = with pkgs; [ curl gnugrep jq ];
        serviceConfig = {
          Type = "oneshot";
          User = "${config.services.graylog.user}";
          ExecStartPre = ''
            +-/bin/sh -c 'chmod 0644 /var/lib/graylog/.graylogConfigured*'
            ExecStartPre=+-/bin/sh -c 'chown graylog:nogroup /var/lib/graylog/.graylogConfigured*'
            ExecStartPre=${pkgs.coreutils}/bin/sleep 60
          '';
          ExecStart = "${graylogPreload}/bin/graylogPreload.sh install ${graylogConfig}";
        };
      };
    }
  ]);
}
