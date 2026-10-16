// CProbes: read-only access to the kernel's energy accounting and the SMC.
//
// Everything here works as a normal user, without root:
//   - resource coalitions: XNU groups an app with every helper it launches into a
//     "resource coalition" and keeps cumulative CPU, GPU and Neural Engine energy for it.
//   - proc_pid_rusage: per-process CPU time and CPU energy.
//   - AppleSMC: whole-machine power (the PSTR key).
#pragma once

#include <stdint.h>
#include <sys/types.h>

/// Cumulative counters for one resource coalition (an app plus its helpers).
typedef struct {
    uint64_t cpu_time_mach;   // Mach absolute time units
    uint64_t cpu_energy_nj;
    uint64_t gpu_time_ns;
    uint64_t gpu_energy_nj;
    uint64_t ane_time_mach;
    uint64_t ane_energy_nj;
} apd_coalition_usage;

/// Cumulative counters for one process.
typedef struct {
    uint64_t cpu_time_mach;   // user + system, Mach absolute time units
    uint64_t cpu_ptime_mach;  // the part of that spent on performance cores
    uint64_t cpu_energy_nj;
} apd_process_usage;

/// Basic facts about a process.
typedef struct {
    pid_t pid;
    pid_t ppid;
    uid_t uid;
    uint32_t status;          // SIDL, SRUN, SSLEEP, SSTOP, SZOMB
    uint64_t start_usec;      // process start, microseconds since the epoch
    char name[32];            // short command name
} apd_process_info;

/// Fills `pids` with every live pid. Returns how many were written, or -1.
int apd_list_pids(pid_t *pids, int capacity);
int apd_process_info_read(pid_t pid, apd_process_info *out);
/// Writes the executable path into `buffer`. Returns its length, or 0 on failure.
int apd_process_path(pid_t pid, char *buffer, uint32_t size);
int apd_process_usage_read(pid_t pid, apd_process_usage *out);

/// Resource-coalition id of a process.
int apd_process_coalition(pid_t pid, uint64_t *cid_out);
int apd_coalition_usage_read(uint64_t cid, apd_coalition_usage *out);
/// Pid of the process that leads a coalition, or -1.
pid_t apd_coalition_leader(uint64_t cid);

/// Nanoseconds per Mach absolute time unit.
double apd_mach_to_ns(void);

/// Opens the AppleSMC user client. Returns 0 on success.
int apd_smc_open(void);
/// Reads a 4-character SMC key of type 'flt '. Returns NaN on failure.
float apd_smc_read_float(const char *key);
void apd_smc_close(void);
