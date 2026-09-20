#!/usr/bin/env bash
set -Eeuo pipefail

BASE="$HOME/main/i/backubserver"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_DIR="$HOME/.config/systemd/user"

mkdir -p "$BASE" "$BIN_DIR" "$SYSTEMD_DIR" "$HOME/.cache"

echo "============================================================"
echo " MAIN SYNC — C++ INSTALLER"
echo "============================================================"

# Do not interrupt an active old/new synchronization.
for LOCK in \
  "$HOME/.cache/main-i-sync.lock" \
  "$HOME/.cache/main-sync-v3.lock" \
  "$HOME/.cache/main-sync.lock"
do
  if [ -e "$LOCK" ] && ! flock -n "$LOCK" true 2>/dev/null; then
    echo ""
    echo "ERROR: synchronization is running: $LOCK"
    echo "Nothing was removed. Run this installer again after it finishes."
    exit 75
  fi
done

need=()
for c in g++ ssh sftp sshfs ssh-keygen ssh-copy-id mountpoint flock sha256sum awk; do
  command -v "$c" >/dev/null 2>&1 || need+=("$c")
done
if [ "${#need[@]}" -gt 0 ]; then
  echo "Installing dependencies: ${need[*]}"
  sudo apt-get update
  sudo apt-get install -y g++ openssh-client sshfs fuse3 util-linux coreutils
fi

cat > "$BASE/main-sync.cpp.new" <<'CPP'
#include <algorithm>
#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <fcntl.h>
#include <iomanip>
#include <iostream>
#include <map>
#include <netdb.h>
#include <poll.h>
#include <set>
#include <sstream>
#include <string>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;
using namespace std::chrono_literals;

struct SyncEntry {
    std::string name;
    std::string local;
    std::string remote;
    bool enabled = true;
};

struct PgEntry {
    std::string name;
    std::string database;
    std::string db_user;
    std::string run_as = "ssh"; // ssh | sudo_postgres
    bool enabled = true;
};

struct Config {
    std::string language = "ru";
    std::string host = "84.39.243.205";
    int port = 61950;
    std::string user = "localhost";
    std::string remote_home = "/home/localhost";
    std::string identity_file = "~/.ssh/main_sync_ed25519";
    double online_seconds = 1.0;
    double offline_seconds = 5.0;
    double full_verify_seconds = 60.0;
    bool postgres_enabled = false;
    int postgres_interval = 3600;
    int postgres_retention = 10;
    std::string postgres_root = "~/PostgreSQL-backups";
    std::vector<SyncEntry> roots;
    std::vector<SyncEntry> files;
    std::vector<PgEntry> databases;
};

static fs::path HOME;
static fs::path BASE;
static fs::path CONFIG_DIR;
static fs::path CONFIG_FILE;
static fs::path STATE_DIR;
static fs::path LOG_FILE;
static fs::path MOUNT_DIR;
static fs::path LOCK_FILE;
static volatile std::sig_atomic_t STOP_REQUESTED = 0;

static void on_signal(int) { STOP_REQUESTED = 1; }

static std::string trim(std::string s) {
    auto not_space = [](unsigned char c){ return !std::isspace(c); };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), not_space));
    s.erase(std::find_if(s.rbegin(), s.rend(), not_space).base(), s.end());
    return s;
}

static std::vector<std::string> split(const std::string& s, char delim) {
    std::vector<std::string> out;
    std::stringstream ss(s);
    std::string item;
    while (std::getline(ss, item, delim)) out.push_back(item);
    return out;
}

static bool to_bool(const std::string& s, bool def = false) {
    std::string x = s;
    std::transform(x.begin(), x.end(), x.begin(), [](unsigned char c){ return std::tolower(c); });
    if (x == "1" || x == "true" || x == "yes" || x == "on") return true;
    if (x == "0" || x == "false" || x == "no" || x == "off") return false;
    return def;
}

static std::string bool_text(bool v) { return v ? "true" : "false"; }

static std::string shell_quote(const std::string& s) {
    std::string out = "'";
    for (char c : s) {
        if (c == '\'') out += "'\\''";
        else out += c;
    }
    out += "'";
    return out;
}

static fs::path expand_home(const std::string& raw) {
    if (raw == "~") return HOME;
    if (raw.rfind("~/", 0) == 0) return HOME / raw.substr(2);
    return fs::path(raw);
}

static std::string now_text() {
    auto now = std::chrono::system_clock::now();
    std::time_t t = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
    localtime_r(&t, &tm);
    std::ostringstream o;
    o << std::put_time(&tm, "%Y-%m-%d %H:%M:%S");
    return o.str();
}

static void log_line(const std::string& s, bool console = true) {
    fs::create_directories(STATE_DIR);
    std::ofstream f(LOG_FILE, std::ios::app);
    f << now_text() << " | " << s << "\n";
    if (console) std::cout << s << "\n";
}

static std::string tr(const Config& c, const std::string& ru, const std::string& en) {
    return c.language == "en" ? en : ru;
}

static Config defaults() {
    Config c;
    c.roots = {
        {"main/i", "~/main/i", "~/main/i", true},
        {"~/.vscode", "~/.vscode", "~/.vscode", true},
        {"~/main/.vscode", "~/main/.vscode", "~/main/.vscode", true}
    };
    c.files = {
        {".bashrc", "~/.bashrc", "~/.bashrc", true}
    };
    return c;
}

static void save_config(const Config& c) {
    fs::create_directories(CONFIG_DIR);
    fs::path tmp = CONFIG_FILE;
    tmp += ".tmp";
    std::ofstream f(tmp, std::ios::trunc);
    if (!f) throw std::runtime_error("cannot write config");
    f << "language=" << c.language << "\n";
    f << "host=" << c.host << "\n";
    f << "port=" << c.port << "\n";
    f << "user=" << c.user << "\n";
    f << "remote_home=" << c.remote_home << "\n";
    f << "identity_file=" << c.identity_file << "\n";
    f << "online_seconds=" << c.online_seconds << "\n";
    f << "offline_seconds=" << c.offline_seconds << "\n";
    f << "full_verify_seconds=" << c.full_verify_seconds << "\n";
    f << "postgres_enabled=" << bool_text(c.postgres_enabled) << "\n";
    f << "postgres_interval=" << c.postgres_interval << "\n";
    f << "postgres_retention=" << c.postgres_retention << "\n";
    f << "postgres_root=" << c.postgres_root << "\n";
    for (const auto& e : c.roots)
        f << "root=" << e.name << "|" << e.local << "|" << e.remote << "|" << bool_text(e.enabled) << "\n";
    for (const auto& e : c.files)
        f << "file=" << e.name << "|" << e.local << "|" << e.remote << "|" << bool_text(e.enabled) << "\n";
    for (const auto& d : c.databases)
        f << "database=" << d.name << "|" << d.database << "|" << d.db_user << "|" << d.run_as << "|" << bool_text(d.enabled) << "\n";
    f.close();
    fs::rename(tmp, CONFIG_FILE);
}

static Config load_config() {
    Config c = defaults();
    if (!fs::exists(CONFIG_FILE)) {
        save_config(c);
        return c;
    }
    c.roots.clear(); c.files.clear(); c.databases.clear();
    std::ifstream f(CONFIG_FILE);
    std::string line;
    while (std::getline(f, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '#') continue;
        auto pos = line.find('=');
        if (pos == std::string::npos) continue;
        std::string k = trim(line.substr(0, pos));
        std::string v = line.substr(pos + 1);
        try {
            if (k == "language") c.language = v;
            else if (k == "host") c.host = v;
            else if (k == "port") c.port = std::stoi(v);
            else if (k == "user") c.user = v;
            else if (k == "remote_home") c.remote_home = v;
            else if (k == "identity_file") c.identity_file = v;
            else if (k == "online_seconds") c.online_seconds = std::stod(v);
            else if (k == "offline_seconds") c.offline_seconds = std::stod(v);
            else if (k == "full_verify_seconds") c.full_verify_seconds = std::stod(v);
            else if (k == "postgres_enabled") c.postgres_enabled = to_bool(v);
            else if (k == "postgres_interval") c.postgres_interval = std::stoi(v);
            else if (k == "postgres_retention") c.postgres_retention = std::stoi(v);
            else if (k == "postgres_root") c.postgres_root = v;
            else if (k == "root" || k == "file") {
                auto p = split(v, '|');
                if (p.size() >= 4) {
                    SyncEntry e{p[0], p[1], p[2], to_bool(p[3], true)};
                    (k == "root" ? c.roots : c.files).push_back(e);
                }
            } else if (k == "database") {
                auto p = split(v, '|');
                if (p.size() >= 5) c.databases.push_back({p[0], p[1], p[2], p[3], to_bool(p[4], true)});
            }
        } catch (...) {}
    }
    if (c.roots.empty() && c.files.empty()) {
        Config d = defaults();
        c.roots = d.roots;
        c.files = d.files;
    }
    return c;
}

static int run(const std::string& cmd, bool quiet = false) {
    std::string q = cmd;
    if (quiet) q += " >/dev/null 2>&1";
    int rc = std::system(q.c_str());
    if (rc == -1) return 127;
    if (WIFEXITED(rc)) return WEXITSTATUS(rc);
    return 128;
}

static std::string capture(const std::string& cmd) {
    FILE* p = popen(cmd.c_str(), "r");
    if (!p) return {};
    char buf[4096];
    std::string out;
    while (fgets(buf, sizeof(buf), p)) out += buf;
    pclose(p);
    return trim(out);
}

static bool command_exists(const std::string& name) {
    return run("command -v " + shell_quote(name), true) == 0;
}

static bool server_online(const Config& c) {
    struct addrinfo hints{};
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    struct addrinfo* res = nullptr;
    std::string port = std::to_string(c.port);
    if (getaddrinfo(c.host.c_str(), port.c_str(), &hints, &res) != 0) return false;
    bool ok = false;
    for (auto* ai = res; ai && !ok; ai = ai->ai_next) {
        int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) ok = true;
        else if (errno == EINPROGRESS) {
            pollfd pfd{fd, POLLOUT, 0};
            int timeout = 3000;
            int pr = poll(&pfd, 1, timeout);
            if (pr > 0) {
                int err = 0; socklen_t len = sizeof(err);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
                ok = (err == 0);
            }
        }
        close(fd);
    }
    freeaddrinfo(res);
    return ok;
}

static bool is_mounted() {
    return run("mountpoint -q " + shell_quote(MOUNT_DIR.string()), true) == 0;
}

static void unmount_remote() {
    if (!is_mounted()) return;
    if (command_exists("fusermount3")) run("fusermount3 -uz " + shell_quote(MOUNT_DIR.string()), true);
    else if (command_exists("fusermount")) run("fusermount -u " + shell_quote(MOUNT_DIR.string()), true);
}

static bool mount_remote(const Config& c) {
    if (is_mounted()) return false;
    fs::create_directories(MOUNT_DIR);
    std::ostringstream cmd;
    cmd << "sshfs -p " << c.port << " "
        << shell_quote(c.user + "@" + c.host + ":" + c.remote_home) << " "
        << shell_quote(MOUNT_DIR.string())
        << " -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=yes -o reconnect";
    fs::path key = expand_home(c.identity_file);
    if (fs::exists(key)) cmd << " -o " << shell_quote("IdentityFile=" + key.string());
    int rc = run(cmd.str());
    if (rc != 0 || !is_mounted()) throw std::runtime_error("SSHFS mount failed");
    return true;
}

static fs::path remote_path(const Config& c, const std::string& r) {
    if (r == "~") return MOUNT_DIR;
    if (r.rfind("~/", 0) == 0) return MOUNT_DIR / r.substr(2);
    if (!r.empty() && r[0] == '/') {
        fs::path rp(r), home(c.remote_home);
        auto rel = rp.lexically_relative(home);
        if (rel.empty() || rel.string().rfind("..",0)==0) throw std::runtime_error("remote path outside remote_home: " + r);
        return MOUNT_DIR / rel;
    }
    return MOUNT_DIR / r;
}

struct LockGuard {
    int fd = -1;
    explicit LockGuard(const fs::path& p) {
        fs::create_directories(p.parent_path());
        fd = open(p.c_str(), O_CREAT | O_RDWR, 0600);
        if (fd < 0) throw std::runtime_error("cannot open lock");
        if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
            close(fd); fd = -1;
            throw std::runtime_error("sync already running");
        }
        ftruncate(fd, 0);
        std::string pid = std::to_string(getpid());
        write(fd, pid.data(), pid.size());
    }
    ~LockGuard(){ if(fd>=0){ flock(fd, LOCK_UN); close(fd);} }
};

static std::string sha256(const fs::path& p) {
    return capture("sha256sum -- " + shell_quote(p.string()) + " | awk '{print $1}'");
}

static std::string human(uintmax_t n) {
    const char* units[] = {"B","KiB","MiB","GiB","TiB"};
    double v = static_cast<double>(n); int u=0;
    while (v >= 1024.0 && u < 4) { v/=1024.0; ++u; }
    std::ostringstream o; o << std::fixed << std::setprecision(1) << v << " " << units[u];
    return o.str();
}

static long long mtime_ns(const fs::path& p) {
    auto t = fs::last_write_time(p).time_since_epoch();
    return std::chrono::duration_cast<std::chrono::nanoseconds>(t).count();
}

static void safe_copy(const fs::path& src, const fs::path& dst) {
    fs::create_directories(dst.parent_path());
    auto before_size = fs::file_size(src);
    auto before_time = mtime_ns(src);
    std::string expected = sha256(src);
    if (expected.empty()) throw std::runtime_error("sha256 failed: " + src.string());
    fs::path tmp = dst.parent_path() / (".main-sync-" + std::to_string(getpid()) + "-" + dst.filename().string());
    std::error_code ec;
    fs::remove(tmp, ec);
    fs::copy_file(src, tmp, fs::copy_options::overwrite_existing);
    if (fs::file_size(tmp) != before_size || sha256(tmp) != expected) {
        fs::remove(tmp, ec);
        throw std::runtime_error("copy verification failed: " + src.string());
    }
    if (fs::file_size(src) != before_size || mtime_ns(src) != before_time) {
        fs::remove(tmp, ec);
        throw std::runtime_error("source changed during copy: " + src.string());
    }
    fs::permissions(tmp, fs::status(src).permissions(), ec);
    fs::last_write_time(tmp, fs::last_write_time(src), ec);
    fs::rename(tmp, dst, ec);
    if (ec) {
        fs::remove(dst, ec);
        ec.clear();
        fs::rename(tmp, dst, ec);
    }
    if (ec) throw std::runtime_error("atomic replace failed: " + dst.string());
    if (sha256(dst) != expected) throw std::runtime_error("final hash mismatch: " + dst.string());
}

struct Counts { int up=0, down=0, same=0, conflict=0; };

static int sync_pair(const fs::path& local, const fs::path& remote, const std::string& name, bool dry, Counts& c) {
    bool le = fs::is_regular_file(local), re = fs::is_regular_file(remote);
    if (le && !re) {
        std::cout << "LOCAL  -> SERVER   " << name << " [" << human(fs::file_size(local)) << "]\n";
        if (!dry) safe_copy(local, remote);
        ++c.up;
        return 1;
    }
    if (re && !le) {
        std::cout << "SERVER -> LOCAL    " << name << " [" << human(fs::file_size(remote)) << "]\n";
        if (!dry) safe_copy(remote, local);
        ++c.down;
        return 1;
    }
    if (!le && !re) return 0;
    auto ls = fs::file_size(local), rs = fs::file_size(remote);
    if (ls > rs) {
        std::cout << "LOCAL  -> SERVER   " << name << " [" << human(ls) << "]\n";
        if (!dry) safe_copy(local, remote);
        ++c.up;
        return 1;
    }
    if (rs > ls) {
        std::cout << "SERVER -> LOCAL    " << name << " [" << human(rs) << "]\n";
        if (!dry) safe_copy(remote, local);
        ++c.down;
        return 1;
    }
    std::string lh = sha256(local), rh = sha256(remote);
    if (lh == rh) { ++c.same; return 0; }
    auto lm = mtime_ns(local), rm = mtime_ns(remote);
    if (lm > rm) {
        std::cout << "LOCAL  -> SERVER   " << name << " [same size, local newer]\n";
        if (!dry) safe_copy(local, remote);
        ++c.up;
        return 1;
    }
    if (rm > lm) {
        std::cout << "SERVER -> LOCAL    " << name << " [same size, server newer]\n";
        if (!dry) safe_copy(remote, local);
        ++c.down;
        return 1;
    }
    std::cout << "CONFLICT           " << name << "\n";
    ++c.conflict; return 0;
}

static std::map<std::string, fs::path> manifest(const fs::path& root) {
    std::map<std::string, fs::path> out;
    if (!fs::exists(root)) return out;
    std::error_code ec;
    for (fs::recursive_directory_iterator it(root, fs::directory_options::skip_permission_denied, ec), end; it != end; it.increment(ec)) {
        if (ec) { ec.clear(); continue; }
        if (it->is_symlink(ec)) { if (it->is_directory(ec)) it.disable_recursion_pending(); continue; }
        if (!it->is_regular_file(ec)) continue;
        auto rel = fs::relative(it->path(), root, ec);
        if (ec) { ec.clear(); continue; }
        if (it->path().filename().string().rfind(".main-sync-", 0) == 0) continue;
        out[rel.generic_string()] = it->path();
    }
    return out;
}

static void sync_root(const Config& cfg, const SyncEntry& e, bool dry, Counts& c) {
    fs::path l = expand_home(e.local), r = remote_path(cfg, e.remote);
    std::cout << "\n=== " << e.name << " ===\nLOCAL : " << l << "\nSERVER: " << e.remote << "\n";
    if (!fs::exists(l) && fs::exists(r) && !dry) fs::create_directories(l);
    auto lm = manifest(l), rm = manifest(r);
    std::set<std::string> keys;
    for (auto& [k,_]:lm) keys.insert(k);
    for (auto& [k,_]:rm) keys.insert(k);
    for (const auto& k:keys) sync_pair(l/k, r/k, k, dry, c);
}

static std::vector<int> parse_selection(const std::string& text, int max) {
    std::string s = trim(text);
    if (s == "a" || s == "all" || s == "*") { std::vector<int> v; for(int i=1;i<=max;++i)v.push_back(i); return v; }
    std::replace(s.begin(), s.end(), ',', ' ');
    std::stringstream ss(s); int x; std::vector<int> out;
    while (ss >> x) if (x>=1 && x<=max && std::find(out.begin(),out.end(),x)==out.end()) out.push_back(x);
    return out;
}

static Counts run_sync(Config& cfg, const std::vector<int>* roots_sel, const std::vector<int>* files_sel, bool dry, bool keep_mount=false) {
    if (!server_online(cfg)) throw std::runtime_error(tr(cfg,"Сервер недоступен","Server is offline"));
    bool mounted_here = mount_remote(cfg);
    LockGuard lock(LOCK_FILE);
    Counts c;
    auto selected = [](int idx, const std::vector<int>* v){ return !v || std::find(v->begin(),v->end(),idx)!=v->end(); };
    try {
        for (size_t i=0;i<cfg.roots.size();++i) if (cfg.roots[i].enabled && selected((int)i+1,roots_sel)) sync_root(cfg,cfg.roots[i],dry,c);
        for (size_t i=0;i<cfg.files.size();++i) if (cfg.files[i].enabled && selected((int)i+1,files_sel)) {
            auto& e=cfg.files[i]; std::cout << "\n=== " << e.name << " ===\n";
            sync_pair(expand_home(e.local),remote_path(cfg,e.remote),e.name,dry,c);
        }
        std::cout << "\nLOCAL -> SERVER: "<<c.up<<"\nSERVER -> LOCAL: "<<c.down<<"\nUNCHANGED: "<<c.same<<"\nCONFLICTS: "<<c.conflict<<"\n";
        if (!dry) log_line("sync ok up="+std::to_string(c.up)+" down="+std::to_string(c.down)+" same="+std::to_string(c.same)+" conflicts="+std::to_string(c.conflict), false);
    } catch (...) {
        if (mounted_here && !keep_mount) unmount_remote();
        throw;
    }
    if (mounted_here && !keep_mount) unmount_remote();
    return c;
}

static uint64_t fingerprint_path(uint64_t h, const fs::path& p) {
    auto mix=[&](const std::string& s){ for(unsigned char c:s){ h^=c; h*=1099511628211ULL; } };
    std::error_code ec;
    if (!fs::exists(p,ec)) { mix(p.string()+"|missing"); return h; }
    if (fs::is_regular_file(p,ec)) {
        mix(p.string()+"|"+std::to_string(fs::file_size(p,ec))+"|"+std::to_string(mtime_ns(p))); return h;
    }
    for (fs::recursive_directory_iterator it(p, fs::directory_options::skip_permission_denied, ec), end; it!=end; it.increment(ec)) {
        if (ec) { ec.clear(); continue; }
        if (it->is_symlink(ec)) { if(it->is_directory(ec)) it.disable_recursion_pending(); continue; }
        if (it->is_regular_file(ec)) mix(it->path().string()+"|"+std::to_string(it->file_size(ec))+"|"+std::to_string(mtime_ns(it->path())));
    }
    return h;
}

static uint64_t fingerprint(const Config& cfg) {
    uint64_t h=1469598103934665603ULL;
    for(const auto& e:cfg.roots) if(e.enabled){ h=fingerprint_path(h,expand_home(e.local)); h=fingerprint_path(h,remote_path(cfg,e.remote)); }
    for(const auto& e:cfg.files) if(e.enabled){ h=fingerprint_path(h,expand_home(e.local)); h=fingerprint_path(h,remote_path(cfg,e.remote)); }
    return h;
}

static std::string ssh_base(const Config& c, bool batch=true) {
    std::ostringstream o;
    o << "ssh -p " << c.port << " ";
    fs::path key=expand_home(c.identity_file);
    if(fs::exists(key)) o << "-i " << shell_quote(key.string()) << " ";
    if(batch) o << "-o BatchMode=yes ";
    o << "-o ConnectTimeout=5 -o StrictHostKeyChecking=yes " << shell_quote(c.user+"@"+c.host);
    return o.str();
}

static std::string sanitize(std::string s) {
    for(char& c:s) if(!std::isalnum((unsigned char)c) && c!='_' && c!='-' && c!='.') c='_';
    return s.empty()?"database":s;
}

static void cleanup_retention(const fs::path& dir, int keep) {
    if (keep<=0 || !fs::exists(dir)) return;
    std::vector<fs::directory_entry> v;
    for(auto& e:fs::directory_iterator(dir)) if(e.is_regular_file() && e.path().extension()==".dump") v.push_back(e);
    std::sort(v.begin(),v.end(),[](auto&a,auto&b){return a.last_write_time()>b.last_write_time();});
    for(size_t i=keep;i<v.size();++i){ std::error_code ec; fs::remove(v[i],ec); }
}

static void pg_backup(Config& cfg, const std::vector<int>* selection=nullptr) {
    if(!cfg.postgres_enabled) throw std::runtime_error(tr(cfg,"PostgreSQL backup выключен","PostgreSQL backup is disabled"));
    if(!server_online(cfg)) throw std::runtime_error(tr(cfg,"Сервер недоступен","Server is offline"));
    LockGuard lock(LOCK_FILE);
    fs::path root=expand_home(cfg.postgres_root); fs::create_directories(root);
    for(size_t i=0;i<cfg.databases.size();++i){
        if(!cfg.databases[i].enabled) continue;
        if(selection && std::find(selection->begin(),selection->end(),(int)i+1)==selection->end()) continue;
        auto& d=cfg.databases[i];
        std::string label=sanitize(d.name.empty()?d.database:d.name);
        fs::path dir=root/label; fs::create_directories(dir);
        auto t=std::time(nullptr); std::tm tm{}; localtime_r(&t,&tm); char stamp[32]; std::strftime(stamp,sizeof(stamp),"%Y%m%d_%H%M%S",&tm);
        fs::path final=dir/(label+"_"+stamp+".dump"); fs::path part=final; part += ".part";
        std::string remote="pg_dump --format=custom --no-owner --no-acl ";
        if(!d.db_user.empty()) remote += "--username " + shell_quote(d.db_user) + " ";
        remote += "--dbname " + shell_quote(d.database);
        if(d.run_as=="sudo_postgres") remote="sudo -n -u postgres "+remote;
        std::string cmd=ssh_base(cfg,true)+" "+shell_quote(remote)+" > "+shell_quote(part.string());
        log_line("postgres backup start: "+d.database);
        int rc=run(cmd);
        if(rc!=0 || !fs::exists(part) || fs::file_size(part)==0){ std::error_code ec; fs::remove(part,ec); throw std::runtime_error("pg_dump failed: "+d.database); }
        fs::rename(part,final);
        cleanup_retention(dir,cfg.postgres_retention);
        log_line("postgres backup ok: "+d.database+" -> "+final.string());
    }
}

static void install_service(const Config& cfg, const fs::path& exe) {
    fs::path unit=HOME/".config/systemd/user/main-sync.service";
    fs::create_directories(unit.parent_path());
    std::ofstream f(unit,std::ios::trunc);
    f << "[Unit]\nDescription=Main Sync C++ daemon\nWants=network-online.target\nAfter=network-online.target\n\n"
      << "[Service]\nType=simple\nExecStart=" << exe.string() << " --daemon\nRestart=always\nRestartSec=5\nNice=10\nIOSchedulingClass=idle\nCPUWeight=20\nIOWeight=20\nTimeoutStopSec=20\n\n"
      << "[Install]\nWantedBy=default.target\n";
    f.close();
    run("systemctl --user daemon-reload");
    run("systemctl --user enable main-sync.service");
    std::cout << tr(cfg,"Systemd unit установлен.","Systemd unit installed.") << "\n";
}

static std::string service_status() {
    return capture("systemctl --user is-active main-sync.service 2>/dev/null || true");
}

static void daemon_loop() {
    std::signal(SIGINT,on_signal); std::signal(SIGTERM,on_signal);
    log_line("daemon started");
    uint64_t last_fp=0; bool have_fp=false; auto last_full=std::chrono::steady_clock::now()-24h; auto last_pg=std::chrono::steady_clock::now()-24h; bool last_online=false;
    while(!STOP_REQUESTED){
        Config cfg=load_config();
        bool online=server_online(cfg);
        if(online!=last_online){ log_line(std::string("server ")+(online?"ONLINE":"OFFLINE")); last_online=online; }
        if(!online){ unmount_remote(); have_fp=false; std::this_thread::sleep_for(std::chrono::duration<double>(std::max(1.0,cfg.offline_seconds))); continue; }
        try{
            mount_remote(cfg);
            auto now=std::chrono::steady_clock::now();
            uint64_t fp=fingerprint(cfg);
            bool changed=!have_fp || fp!=last_fp;
            bool full_due=std::chrono::duration<double>(now-last_full).count()>=cfg.full_verify_seconds;
            if(changed || full_due){
                try{ run_sync(cfg,nullptr,nullptr,false,true); last_fp=fingerprint(cfg); have_fp=true; last_full=std::chrono::steady_clock::now(); }
                catch(const std::exception& e){ log_line(std::string("sync error: ")+e.what()); }
            }
            if(cfg.postgres_enabled && std::chrono::duration<double>(now-last_pg).count()>=std::max(60,cfg.postgres_interval)){
                try{ pg_backup(cfg,nullptr); last_pg=std::chrono::steady_clock::now(); }
                catch(const std::exception& e){ log_line(std::string("postgres error: ")+e.what()); }
            }
        }catch(const std::exception& e){ log_line(std::string("daemon cycle error: ")+e.what()); unmount_remote(); have_fp=false; }
        std::this_thread::sleep_for(std::chrono::duration<double>(std::max(0.5,cfg.online_seconds)));
    }
    unmount_remote(); log_line("daemon stopped");
}

static std::string input(const std::string& prompt) { std::cout<<prompt; std::string s; std::getline(std::cin,s); return trim(s); }
static void pause_menu(const Config& c){ input("\n"+tr(c,"Enter — продолжить...","Enter — continue...")+" "); }
static void clear_screen(){ std::cout << "\033[2J\033[H"; }

static void list_entries(const Config&, const std::vector<SyncEntry>& v, const std::string& title){
    std::cout << "\n"<<title<<"\n";
    for(size_t i=0;i<v.size();++i) std::cout<<" "<<i+1<<") "<<(v[i].enabled?"[ON] ":"[OFF] ")<<v[i].name<<"\n    LOCAL : "<<v[i].local<<"\n    SERVER: "<<v[i].remote<<"\n";
    if(v.empty()) std::cout<<" (empty)\n";
}

static void manage_paths(Config& c){
    while(true){ clear_screen(); list_entries(c,c.roots,tr(c,"ПАПКИ","FOLDERS")); list_entries(c,c.files,tr(c,"ФАЙЛЫ","FILES"));
        std::cout<<"\n1) "<<tr(c,"Добавить папку","Add folder")<<"\n2) "<<tr(c,"Добавить файл","Add file")<<"\n3) "<<tr(c,"Удалить папку","Remove folder")<<"\n4) "<<tr(c,"Удалить файл","Remove file")<<"\n5) "<<tr(c,"Вкл/выкл папку","Toggle folder")<<"\n6) "<<tr(c,"Вкл/выкл файл","Toggle file")<<"\n0) "<<tr(c,"Назад","Back")<<"\n";
        std::string ch=input("> "); if(ch=="0")return;
        try{
            if(ch=="1"||ch=="2"){
                SyncEntry e; e.name=input(tr(c,"Название: ","Name: ")); e.local=input("LOCAL: "); e.remote=input(tr(c,"SERVER [Enter = такой же]: ","SERVER [Enter = same]: "));
                if(e.remote.empty()){ fs::path lp=expand_home(e.local); auto rel=lp.lexically_relative(HOME); e.remote="~/"+rel.generic_string(); }
                e.enabled=true; (ch=="1"?c.roots:c.files).push_back(e); save_config(c);
            }else if(ch=="3"||ch=="4"||ch=="5"||ch=="6"){
                auto& v=(ch=="3"||ch=="5")?c.roots:c.files; int n=std::stoi(input(tr(c,"Номер: ","Number: "))); if(n<1||n>(int)v.size())continue;
                if(ch=="3"||ch=="4")v.erase(v.begin()+n-1); else v[n-1].enabled=!v[n-1].enabled; save_config(c);
            }
        }catch(const std::exception&e){std::cout<<e.what()<<"\n";pause_menu(c);} }
}

static void server_menu(Config& c){
    while(true){ clear_screen(); std::cout<<tr(c,"СЕРВЕР / SSH","SERVER / SSH")<<"\n\nHost: "<<c.host<<"\nPort: "<<c.port<<"\nUser: "<<c.user<<"\nRemote home: "<<c.remote_home<<"\nKey: "<<c.identity_file<<"\n\n1) "<<tr(c,"Изменить сервер","Edit server")<<"\n2) "<<tr(c,"Сгенерировать SSH key","Generate SSH key")<<"\n3) "<<tr(c,"Прокинуть SSH key","Copy SSH key")<<"\n4) "<<tr(c,"Проверить SSH/SFTP","Test SSH/SFTP")<<"\n0) "<<tr(c,"Назад","Back")<<"\n";
        std::string ch=input("> "); if(ch=="0")return;
        if(ch=="1"){
            std::string s=input("Host ["+c.host+"]: "); if(!s.empty())c.host=s; s=input("Port ["+std::to_string(c.port)+"]: "); if(!s.empty())c.port=std::stoi(s); s=input("User ["+c.user+"]: "); if(!s.empty())c.user=s; s=input("Remote home ["+c.remote_home+"]: "); if(!s.empty())c.remote_home=s; s=input("Key ["+c.identity_file+"]: "); if(!s.empty())c.identity_file=s; save_config(c);
        }else if(ch=="2"){
            fs::path key=expand_home(c.identity_file); fs::create_directories(key.parent_path());
            std::string cmd="ssh-keygen -t ed25519 -a 64 -N '' -f "+shell_quote(key.string())+" -C "+shell_quote("main-sync@"+capture("hostname")); run(cmd); pause_menu(c);
        }else if(ch=="3"){
            fs::path pub=expand_home(c.identity_file); pub += ".pub"; std::string cmd="ssh-copy-id -i "+shell_quote(pub.string())+" -p "+std::to_string(c.port)+" "+shell_quote(c.user+"@"+c.host); run(cmd); pause_menu(c);
        }else if(ch=="4"){
            fs::path key=expand_home(c.identity_file); std::ostringstream cmd; cmd<<"printf 'pwd\\nquit\\n' | sftp -q -b - -P "<<c.port<<" -o BatchMode=yes "; if(fs::exists(key))cmd<<"-i "<<shell_quote(key.string())<<" "; cmd<<shell_quote(c.user+"@"+c.host); int rc=run(cmd.str()); std::cout<<(rc==0?"OK":"FAILED")<<"\n"; pause_menu(c);
        }
    }
}

static void daemon_menu(Config& c, const fs::path& exe){
    while(true){ clear_screen(); std::cout<<tr(c,"DAEMON / SYSTEMD","DAEMON / SYSTEMD")<<"\n\nOnline: "<<c.online_seconds<<" s\nOffline: "<<c.offline_seconds<<" s\nFull verify: "<<c.full_verify_seconds<<" s\nStatus: "<<service_status()<<"\n\n1) "<<tr(c,"Интервалы","Intervals")<<"\n2) Start\n3) Stop\n4) Restart\n5) Enable\n6) Disable\n7) "<<tr(c,"Установить/обновить unit","Install/update unit")<<"\n8) "<<tr(c,"Enable linger","Enable linger")<<"\n0) "<<tr(c,"Назад","Back")<<"\n";
        std::string ch=input("> "); if(ch=="0")return;
        if(ch=="1"){std::string s=input("online_seconds: ");if(!s.empty())c.online_seconds=std::stod(s);s=input("offline_seconds: ");if(!s.empty())c.offline_seconds=std::stod(s);s=input("full_verify_seconds: ");if(!s.empty())c.full_verify_seconds=std::stod(s);save_config(c);}
        else if(ch=="2")run("systemctl --user start main-sync.service"); else if(ch=="3")run("systemctl --user stop main-sync.service"); else if(ch=="4")run("systemctl --user restart main-sync.service"); else if(ch=="5")run("systemctl --user enable main-sync.service"); else if(ch=="6")run("systemctl --user disable main-sync.service"); else if(ch=="7")install_service(c,exe); else if(ch=="8")run("sudo loginctl enable-linger "+shell_quote(capture("id -un")));
    }
}

static void pg_menu(Config& c){
    while(true){ clear_screen(); std::cout<<"PostgreSQL: "<<(c.postgres_enabled?"ON":"OFF")<<"\nInterval: "<<c.postgres_interval<<"\nRetention: "<<c.postgres_retention<<"\nRoot: "<<c.postgres_root<<"\n\n";
        for(size_t i=0;i<c.databases.size();++i)std::cout<<i+1<<") "<<(c.databases[i].enabled?"[ON] ":"[OFF] ")<<c.databases[i].name<<" -> "<<c.databases[i].database<<"\n";
        std::cout<<"\n1) Toggle PostgreSQL\n2) "<<tr(c,"Добавить базу","Add database")<<"\n3) "<<tr(c,"Удалить базу","Remove database")<<"\n4) "<<tr(c,"Вкл/выкл базу","Toggle database")<<"\n5) "<<tr(c,"Backup сейчас","Backup now")<<"\n6) "<<tr(c,"Настройки","Settings")<<"\n0) "<<tr(c,"Назад","Back")<<"\n";
        std::string ch=input("> "); if(ch=="0")return;
        if(ch=="1"){c.postgres_enabled=!c.postgres_enabled;save_config(c);} else if(ch=="2"){PgEntry d;d.name=input(tr(c,"Название: ","Name: "));d.database=input("Database: ");d.db_user=input("DB user [Enter=default]: ");std::string m=input("run_as [ssh/sudo_postgres]: ");if(!m.empty())d.run_as=m;d.enabled=true;c.databases.push_back(d);save_config(c);} else if(ch=="3"||ch=="4"){int n=std::stoi(input(tr(c,"Номер: ","Number: ")));if(n>=1&&n<=(int)c.databases.size()){if(ch=="3")c.databases.erase(c.databases.begin()+n-1);else c.databases[n-1].enabled=!c.databases[n-1].enabled;save_config(c);}} else if(ch=="5"){auto sel=parse_selection(input(tr(c,"Номера через пробел или a: ","Numbers separated by spaces or a: ")),(int)c.databases.size());try{pg_backup(c,&sel);}catch(const std::exception&e){std::cout<<e.what()<<"\n";}pause_menu(c);} else if(ch=="6"){std::string s=input("interval_seconds ["+std::to_string(c.postgres_interval)+"]: ");if(!s.empty())c.postgres_interval=std::stoi(s);s=input("retention ["+std::to_string(c.postgres_retention)+"]: ");if(!s.empty())c.postgres_retention=std::stoi(s);s=input("root ["+c.postgres_root+"]: ");if(!s.empty())c.postgres_root=s;save_config(c);}
    }
}

static void show_logs(const Config& c){
    std::ifstream f(LOG_FILE); std::vector<std::string> lines; std::string s; while(std::getline(f,s)){lines.push_back(s);if(lines.size()>200)lines.erase(lines.begin());}
    std::cout<<"\n--- LOG ---\n"; for(auto&x:lines)std::cout<<x<<"\n"; pause_menu(c);
}

static void dashboard(const Config& c){
    bool online=server_online(c); std::cout<<"╔══════════════════════════════════════════════════════════╗\n║                    MAIN SYNC C++                         ║\n╚══════════════════════════════════════════════════════════╝\n";
    std::cout<<(online?"🟢 ":"🔴 ")<<c.user<<"@"<<c.host<<":"<<c.port<<"  "<<(online?"ONLINE":"OFFLINE")<<"\n";
    std::cout<<"⚙️  daemon: "<<service_status()<<"\n";
}

static void menu(const fs::path& exe){
    Config c=load_config();
    while(true){c=load_config();clear_screen();dashboard(c);std::cout<<"\n1) "<<tr(c,"🔄 Синхронизировать всё","🔄 Sync all")<<"\n2) "<<tr(c,"📁 Выбрать папки (1 2 4)","📁 Select folders (1 2 4)")<<"\n3) "<<tr(c,"📄 Выбрать файлы","📄 Select files")<<"\n4) "<<tr(c,"👀 Dry run","👀 Dry run")<<"\n5) "<<tr(c,"➕ Управление путями","➕ Manage paths")<<"\n6) "<<tr(c,"🔐 Сервер / SSH","🔐 Server / SSH")<<"\n7) "<<tr(c,"⚙️ Daemon / systemd","⚙️ Daemon / systemd")<<"\n8) 🐘 PostgreSQL\n9) "<<tr(c,"📜 Логи","📜 Logs")<<"\n10) "<<tr(c,"🌐 Язык RU/EN","🌐 Language RU/EN")<<"\n0) "<<tr(c,"Выход","Exit")<<"\n";
        std::string ch=input("\n> "); try{
            if(ch=="0") return;
            if(ch=="1"){run_sync(c,nullptr,nullptr,false);pause_menu(c);} else if(ch=="2"){list_entries(c,c.roots,tr(c,"ПАПКИ","FOLDERS"));auto sel=parse_selection(input(tr(c,"Номера через пробел или a: ","Numbers or a: ")),(int)c.roots.size());std::vector<int> none;run_sync(c,&sel,&none,false);pause_menu(c);} else if(ch=="3"){list_entries(c,c.files,tr(c,"ФАЙЛЫ","FILES"));auto sel=parse_selection(input(tr(c,"Номера через пробел или a: ","Numbers or a: ")),(int)c.files.size());std::vector<int> none;run_sync(c,&none,&sel,false);pause_menu(c);} else if(ch=="4"){list_entries(c,c.roots,tr(c,"ПАПКИ","FOLDERS"));auto rs=parse_selection(input(tr(c,"Папки: ","Folders: ")),(int)c.roots.size());list_entries(c,c.files,tr(c,"ФАЙЛЫ","FILES"));auto fsx=parse_selection(input(tr(c,"Файлы: ","Files: ")),(int)c.files.size());run_sync(c,&rs,&fsx,true);pause_menu(c);} else if(ch=="5")manage_paths(c); else if(ch=="6")server_menu(c); else if(ch=="7")daemon_menu(c,exe); else if(ch=="8")pg_menu(c); else if(ch=="9")show_logs(c); else if(ch=="10"){c.language=(c.language=="ru"?"en":"ru");save_config(c);} }
        catch(const std::exception&e){std::cout<<"\nERROR: "<<e.what()<<"\n";pause_menu(c);} }
}

static fs::path self_exe(){ char buf[4096]; ssize_t n=readlink("/proc/self/exe",buf,sizeof(buf)-1); if(n>0){buf[n]=0;return fs::path(buf);} return fs::absolute("main-sync"); }

static void init_paths(){ const char* h=std::getenv("HOME"); if(!h)throw std::runtime_error("HOME not set"); HOME=fs::path(h); BASE=HOME/"main/i/backubserver"; CONFIG_DIR=HOME/".config/main-sync"; CONFIG_FILE=CONFIG_DIR/"config.ini"; STATE_DIR=HOME/".local/state/main-sync"; LOG_FILE=STATE_DIR/"main-sync.log"; MOUNT_DIR=HOME/".cache/main-sync-remote"; LOCK_FILE=HOME/".cache/main-sync.lock"; fs::create_directories(BASE);fs::create_directories(CONFIG_DIR);fs::create_directories(STATE_DIR); }

static void help(){ std::cout<<"main-sync [--menu|--sync|--dry-run|--daemon|--status|--install-service|--pg-backup|--config]\n"; }

int main(int argc,char**argv){
    try{
        init_paths(); Config cfg=load_config(); fs::path exe=self_exe();
        std::string a=argc>1?argv[1]:"--menu";
        if(a=="--help"||a=="-h"){help();return 0;} if(a=="--menu"){menu(exe);return 0;} if(a=="--daemon"){daemon_loop();return 0;} if(a=="--sync"){run_sync(cfg,nullptr,nullptr,false);return 0;} if(a=="--dry-run"){run_sync(cfg,nullptr,nullptr,true);return 0;} if(a=="--status"){dashboard(cfg);return 0;} if(a=="--install-service"){install_service(cfg,exe);return 0;} if(a=="--pg-backup"){pg_backup(cfg,nullptr);return 0;} if(a=="--config"){std::cout<<CONFIG_FILE<<"\n";return 0;} help(); return 2;
    }catch(const std::exception&e){std::cerr<<"ERROR: "<<e.what()<<"\n";return 1;}
}

CPP

cat > "$BASE/README.md.new" <<'README'
# Main Sync C++

## Русский

`main-sync` — один C++-бинарник для двусторонней синхронизации файлов между локальным Linux-компьютером и удалённым Linux-сервером через SSHFS.

### Возможности

- одно интерактивное меню без Python и без отдельного `.sh`-меню;
- русский и английский интерфейс;
- сервер, SSH-порт, пользователь, remote home и путь к ключу настраиваются из меню;
- генерация Ed25519-ключа и установка ключа через `ssh-copy-id`;
- любое количество синхронизируемых папок и отдельных файлов;
- выбор нескольких пунктов через пробел, например `1 2 4`, либо `a` для всех;
- user-systemd daemon;
- отдельные интервалы проверки для online/offline сервера;
- лёгкая проверка metadata и периодическая полная проверка SHA-256;
- локальный журнал;
- PostgreSQL backup через удалённый `pg_dump`;
- ограничение количества `.dump`-копий;
- блокировка от одновременного ручного и daemon-sync.

### Логика синхронизации

1. Файл существует только с одной стороны — он копируется на отсутствующую сторону.
2. Если размеры отличаются, **больший файл считается новой копией**.
3. Если размеры одинаковые, сравнивается SHA-256.
4. Если SHA-256 различается, побеждает более новый `mtime`.
5. При одинаковом размере, одинаковом времени, но разном SHA-256 файл отмечается как conflict.
6. Автоматического удаления файлов нет.

> Важно: правило «больший файл = новая копия» означает, что новая редакция файла, ставшая меньше старой, может быть заменена старой большей копией. Это сознательно сохранено по текущей логике проекта.

### Запуск

```bash
main-sync
```

Другие команды:

```bash
main-sync --sync
main-sync --dry-run
main-sync --status
main-sync --daemon
main-sync --pg-backup
main-sync --install-service
main-sync --config
```

### Файлы

- исходник: `~/main/i/backubserver/main-sync.cpp`
- бинарник: `~/main/i/backubserver/main-sync`
- команда: `~/.local/bin/main-sync`
- конфиг: `~/.config/main-sync/config.ini`
- лог: `~/.local/state/main-sync/main-sync.log`
- mount: `~/.cache/main-sync-remote`
- systemd: `~/.config/systemd/user/main-sync.service`

### Конфиг

Конфиг создаётся программой автоматически. Его можно менять через меню или вручную.

Пример:

```ini
language=ru
host=84.39.243.205
port=61950
user=localhost
remote_home=/home/localhost
identity_file=~/.ssh/main_sync_ed25519
online_seconds=1
offline_seconds=5
full_verify_seconds=60
postgres_enabled=false
postgres_interval=3600
postgres_retention=10
postgres_root=~/PostgreSQL-backups
root=main/i|~/main/i|~/main/i|true
file=.bashrc|~/.bashrc|~/.bashrc|true
```

Символ `|` зарезервирован как разделитель и не должен использоваться в имени или пути.

### PostgreSQL

На удалённом сервере должен быть установлен `pg_dump`.

Программа поддерживает два режима:

- `ssh` — `pg_dump` запускается от SSH-пользователя;
- `sudo_postgres` — `sudo -n -u postgres pg_dump ...`.

Во втором случае сервер должен разрешать нужную команду без интерактивного sudo-пароля. PostgreSQL-пароли в `config.ini` не сохраняются.

Дампы сначала пишутся как `.part`, а после успешного завершения переименовываются в `.dump`.

### Systemd

Установить/обновить unit можно из меню или:

```bash
main-sync --install-service
systemctl --user restart main-sync.service
```

Для запуска user-service ещё до интерактивного входа можно включить linger:

```bash
sudo loginctl enable-linger "$USER"
```

---

## English

`main-sync` is a single C++ binary for bidirectional file synchronization between a local Linux machine and a remote Linux server over SSHFS.

### Features

- one interactive application; no Python runtime and no separate shell menu;
- Russian and English UI;
- configurable server host, SSH port, user, remote home and SSH key;
- Ed25519 key generation and `ssh-copy-id` setup;
- any number of synchronized folders and individual files;
- multi-selection such as `1 2 4`, or `a` for all;
- user-systemd daemon;
- separate online/offline polling intervals;
- lightweight metadata checks plus periodic SHA-256 verification;
- local logging;
- PostgreSQL backup using remote `pg_dump`;
- dump retention;
- lock protection against simultaneous manual and daemon syncs.

### Synchronization rules

1. A file present on only one side is copied to the missing side.
2. If sizes differ, the **larger file is treated as the newer copy**.
3. Equal sizes are compared using SHA-256.
4. If hashes differ, newer `mtime` wins.
5. Equal size + equal mtime + different hashes becomes a conflict.
6. Files are never automatically deleted.

> Important: under the “larger file wins” rule, a genuinely newer edit that made a file smaller can be overwritten by an older larger copy. This behavior is intentionally preserved from the current project logic.

### Start

```bash
main-sync
```

Other commands:

```bash
main-sync --sync
main-sync --dry-run
main-sync --status
main-sync --daemon
main-sync --pg-backup
main-sync --install-service
main-sync --config
```

### Paths

- source: `~/main/i/backubserver/main-sync.cpp`
- binary: `~/main/i/backubserver/main-sync`
- command: `~/.local/bin/main-sync`
- configuration: `~/.config/main-sync/config.ini`
- log: `~/.local/state/main-sync/main-sync.log`
- SSHFS mount: `~/.cache/main-sync-remote`
- systemd unit: `~/.config/systemd/user/main-sync.service`

### PostgreSQL

`pg_dump` must be installed on the remote server. The program supports running it as the SSH account or as `postgres` using non-interactive `sudo -n`. Database passwords are not stored in `config.ini`.

README

echo "Compiling C++17..."
g++ -x c++ -std=c++17 -O2 -Wall -Wextra -pedantic \
  "$BASE/main-sync.cpp.new" \
  -o "$BASE/main-sync.new"

"$BASE/main-sync.new" --help

echo "Build OK. Removing old Python/shell sync implementation..."

for SERVICE in main-i-sync.service main-i-sync-watch.service main-sync-v3.service main-sync.service; do
  systemctl --user stop "$SERVICE" >/dev/null 2>&1 || true
  systemctl --user disable "$SERVICE" >/dev/null 2>&1 || true
done

for M in \
  "$HOME/.cache/main-i-sync-remote" \
  "$HOME/.cache/main-sync-v3-remote" \
  "$HOME/.cache/main-sync-remote"
do
  if mountpoint -q "$M" 2>/dev/null; then
    if command -v fusermount3 >/dev/null 2>&1; then
      fusermount3 -uz "$M" >/dev/null 2>&1 || true
    else
      fusermount -u "$M" >/dev/null 2>&1 || true
    fi
  fi
done

rm -f \
  "$BASE/index.sh" \
  "$BASE/b.sh" \
  "$BASE/main-i-sync.py" \
  "$BASE/main-i-sync-v2.py" \
  "$BASE/main-i-sync-watch.py" \
  "$BASE/sync-menu.sh" \
  "$BASE/sync-config.json" \
  "$BASE/main-sync-v3.py" \
  "$BASE/sync-menu-v3.sh" \
  "$BASE/sync-config-v3.json" \
  "$HOME/b.sh" \
  "$HOME/sync-menu.sh" \
  "$HOME/.local/bin/main-i-sync.py" \
  "$SYSTEMD_DIR/main-i-sync.service" \
  "$SYSTEMD_DIR/main-i-sync-watch.service" \
  "$SYSTEMD_DIR/main-sync-v3.service"

rm -rf \
  "$BASE/__pycache__" \
  "$HOME/.local/share/main-i-sync" \
  "$HOME/.local/state/main-sync-v3" \
  "$HOME/.cache/main-i-sync-remote" \
  "$HOME/.cache/main-sync-v3-remote"

# User backup/conflict data, SSH keys and PostgreSQL dumps are intentionally preserved.

mv -f "$BASE/main-sync.cpp.new" "$BASE/main-sync.cpp"
mv -f "$BASE/README.md.new" "$BASE/README.md"
mv -f "$BASE/main-sync.new" "$BASE/main-sync"
chmod 700 "$BASE/main-sync"
ln -sfn "$BASE/main-sync" "$BIN_DIR/main-sync"

"$BASE/main-sync" --install-service
systemctl --user daemon-reload
systemctl --user enable main-sync.service
systemctl --user restart main-sync.service || true

echo ""
echo "============================================================"
echo " INSTALLED"
echo "============================================================"
echo "Source : $BASE/main-sync.cpp"
echo "Binary : $BASE/main-sync"
echo "README : $BASE/README.md"
echo "Config : $HOME/.config/main-sync/config.ini"
echo "Log    : $HOME/.local/state/main-sync/main-sync.log"
echo "Menu   : main-sync"
echo ""
"$BASE/main-sync" --status || true
