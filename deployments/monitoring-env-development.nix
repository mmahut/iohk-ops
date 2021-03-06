{
  require = [ ./monitoring.nix ];
  monitoring = { ... }:
  {
    imports = [
      ../modules/development.nix
    ];
    services.monitoring-services.applicationDashboards = ../modules/grafana/cardano;
    services.monitoring-services.applicationRules = [ ];
  };
}
