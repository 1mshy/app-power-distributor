#include "CProbes.h"

#include <libproc.h>
#include <mach/mach_time.h>
#include <math.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <xpc/xpc.h>
#include <IOKit/IOKitLib.h>

// MARK: - Processes

int apd_list_pids(pid_t *pids, int capacity) {
    int n = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    return n < 0 ? -1 : n;
}

int apd_process_info_read(pid_t pid, apd_process_info *out) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != (int)sizeof info) return -1;
    out->pid = (pid_t)info.pbi_pid;
    out->ppid = (pid_t)info.pbi_ppid;
    out->uid = info.pbi_uid;
    out->status = info.pbi_status;
    out->start_usec = info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
    strlcpy(out->name, info.pbi_name[0] ? info.pbi_name : info.pbi_comm, sizeof out->name);
    return 0;
}

int apd_process_path(pid_t pid, char *buffer, uint32_t size) {
    int n = proc_pidpath(pid, buffer, size);
    return n > 0 ? n : 0;
}

int apd_process_usage_read(pid_t pid, apd_process_usage *out) {
    struct rusage_info_v6 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) return -1;
    out->cpu_time_mach = ri.ri_user_time + ri.ri_system_time;
    out->cpu_ptime_mach = ri.ri_user_ptime + ri.ri_system_ptime;
    out->cpu_energy_nj = ri.ri_energy_nj;
    return 0;
}

// MARK: - Coalitions
//
// Neither struct is in the public SDK. Layouts follow XNU's osfmk/mach/coalition.h and
// bsd/sys/proc_info.h; the kernel copies min(our size, its size), so a prefix is enough.

#define APD_COALITION_TYPE_RESOURCE 0
#define APD_COALITION_NUM_TYPES 2
#define APD_PROC_PIDCOALITIONINFO 20

struct apd_xnu_coalition_resource_usage {
    uint64_t tasks_started;
    uint64_t tasks_exited;
    uint64_t time_nonempty;
    uint64_t cpu_time;
    uint64_t interrupt_wakeups;
    uint64_t platform_idle_wakeups;
    uint64_t bytesread;
    uint64_t byteswritten;
    uint64_t gpu_time;
    uint64_t cpu_time_billed_to_me;
    uint64_t cpu_time_billed_to_others;
    uint64_t energy;
    uint64_t logical_writes[8];
    uint64_t energy_billed_to_me;
    uint64_t energy_billed_to_others;
    uint64_t cpu_ptime;
    uint64_t cpu_time_eqos_len;
    uint64_t cpu_time_eqos[7];
    uint64_t cpu_instructions;
    uint64_t cpu_cycles;
    uint64_t fs_metadata_writes;
    uint64_t pm_writes;
    uint64_t cpu_pinstructions;
    uint64_t cpu_pcycles;
    uint64_t conclave_mem;
    uint64_t ane_mach_time;
    uint64_t ane_energy_nj;
    uint64_t phys_footprint;
    uint64_t gpu_energy_nj;
    uint64_t gpu_energy_nj_billed_to_me;
    uint64_t gpu_energy_nj_billed_to_others;
    uint64_t swapins;
};

struct apd_xnu_proc_pidcoalitioninfo {
    uint64_t coalition_id[APD_COALITION_NUM_TYPES];
    uint64_t reserved[3];
};

extern int coalition_info_resource_usage(uint64_t cid, struct apd_xnu_coalition_resource_usage *cru, size_t sz);
extern xpc_object_t xpc_coalition_copy_info(uint64_t cid);

int apd_process_coalition(pid_t pid, uint64_t *cid_out) {
    struct apd_xnu_proc_pidcoalitioninfo info;
    if (proc_pidinfo(pid, APD_PROC_PIDCOALITIONINFO, 0, &info, sizeof info) != (int)sizeof info) return -1;
    *cid_out = info.coalition_id[APD_COALITION_TYPE_RESOURCE];
    return 0;
}

int apd_coalition_usage_read(uint64_t cid, apd_coalition_usage *out) {
    struct apd_xnu_coalition_resource_usage cru;
    memset(&cru, 0, sizeof cru);
    if (coalition_info_resource_usage(cid, &cru, sizeof cru) != 0) return -1;
    out->cpu_time_mach = cru.cpu_time;
    out->cpu_energy_nj = cru.energy;
    out->gpu_time_ns = cru.gpu_time;
    out->gpu_energy_nj = cru.gpu_energy_nj;
    out->ane_time_mach = cru.ane_mach_time;
    out->ane_energy_nj = cru.ane_energy_nj;
    return 0;
}

pid_t apd_coalition_leader(uint64_t cid) {
    xpc_object_t info = xpc_coalition_copy_info(cid);
    if (info == NULL) return -1;
    pid_t leader = -1;
    if (xpc_get_type(info) == XPC_TYPE_DICTIONARY) {
        int64_t value = xpc_dictionary_get_int64(info, "leader-pid");
        if (value > 0) leader = (pid_t)value;
    }
    xpc_release(info);
    return leader;
}

double apd_mach_to_ns(void) {
    static double ratio = 0;
    if (ratio == 0) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        ratio = (double)tb.numer / (double)tb.denom;
    }
    return ratio;
}

// MARK: - SMC

typedef struct {
    uint32_t key;
    uint8_t vers[6];
    uint16_t pad0;
    uint16_t plimit_version, plimit_length;
    uint32_t cpu_plimit, gpu_plimit, mem_plimit;
    uint32_t data_size, data_type;
    uint8_t data_attributes;
    uint8_t pad1[3];
    uint8_t result, status, data8;
    uint8_t pad2;
    uint32_t data32;
    uint8_t bytes[32];
} apd_smc_param;

_Static_assert(sizeof(apd_smc_param) == 80, "AppleSMC expects an 80-byte parameter block");

enum { APD_SMC_KERNEL_INDEX = 2, APD_SMC_READ_BYTES = 5, APD_SMC_READ_KEYINFO = 9 };

static io_connect_t smc_connection = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

static int smc_call(apd_smc_param *in, apd_smc_param *out) {
    size_t out_size = sizeof *out;
    kern_return_t kr = IOConnectCallStructMethod(smc_connection, APD_SMC_KERNEL_INDEX, in, sizeof *in, out, &out_size);
    return (kr == KERN_SUCCESS && out->result == 0) ? 0 : -1;
}

int apd_smc_open(void) {
    if (smc_connection) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &smc_connection);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) {
        smc_connection = 0;
        return -1;
    }
    return 0;
}

float apd_smc_read_float(const char *key) {
    if (!smc_connection || strlen(key) != 4) return NAN;
    apd_smc_param in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.data8 = APD_SMC_READ_KEYINFO;
    if (smc_call(&in, &out) != 0 || out.data_type != fourcc("flt ") || out.data_size != 4) return NAN;

    uint32_t size = out.data_size;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.data_size = size;
    in.data8 = APD_SMC_READ_BYTES;
    if (smc_call(&in, &out) != 0) return NAN;
    float value;
    memcpy(&value, out.bytes, sizeof value);
    return value;
}

void apd_smc_close(void) {
    if (smc_connection) IOServiceClose(smc_connection);
    smc_connection = 0;
}
