# Nightly off-site backups with restic to the host's Backblaze B2 repository
# (settings.backup_repo, i.e. <bucket>/<hostname>). Hosts declare what to back up:
#
#   homelab.backup.paths = [ "/var/lib/foo" ];
#   homelab.backup.postgresql.databases = [ "foo" ];
#
# 02:00  pg_dump of the listed databases -> /var/backup/postgresql
# 03:00  restic uploads the dumps + paths (missing paths are skipped)
{ config, lib, settings, ... }:
let
  cfg = config.homelab.backup;
  repo = settings.backup_repo or "";
  dumps = lib.optional (cfg.postgresql.databases != [ ]) "/var/backup/postgresql";
  allPaths = dumps ++ cfg.paths;
in
{
  options.homelab.backup = {
    paths = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "Paths to back up. Paths that don't exist (yet) are skipped.";
    };
    postgresql.databases = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "PostgreSQL databases to dump before each backup.";
    };
  };

  config = lib.mkIf (repo != "" && allPaths != [ ]) {
    services.postgresqlBackup = lib.mkIf (cfg.postgresql.databases != [ ]) {
      enable = true;
      databases = cfg.postgresql.databases;
      startAt = "*-*-* 02:00:00";
      compression = "none"; # restic compresses + deduplicates better on plain SQL
    };

    # Unit restic-backups-b2, CLI wrapper restic-b2.
    services.restic.backups.b2 = {
      repository = repo;
      environmentFile = "/var/lib/secrets/restic.env";
      passwordFile = "/var/lib/secrets/restic-password";
      initialize = true;
      dynamicFilesFrom = ''
        for p in ${lib.escapeShellArgs allPaths}; do
          [ -e "$p" ] && echo "$p"
        done
        true
      '';
      timerConfig = {
        OnCalendar = "03:00";
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
      pruneOpts = [
        "--keep-daily 7"
        "--keep-weekly 4"
        "--keep-monthly 6"
      ];
      checkOpts = [ "--read-data-subset=5%" ];
    };
  };
}
