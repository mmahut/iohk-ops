{ name, config, resources, ... }:

with import ../lib.nix;
{
  config = {

    global = {
      allocateElasticIP = true;
      enableEkgWeb      = false;
      dnsDomainname     = "cardano-mainnet.iohk.io";
    };

    services = {

      # DEVOPS-64: disable log bursting
      journald.rateLimitBurst    = 0;

      monitoring-exporters.graylogHost = "${config.deployment.arguments.globals.monitoringNV.name}-ip:5044";
    };

  };
}
