// SPDX-License-Identifier: GPL-2.0
/*
 * Validate that a stale per-hart Vector owner from a destroyed vCPU cannot
 * be treated as the owner of a different vCPU.
 */
#include <stdio.h>

#include "kvm_syscalls.h"
#include "kvm_util.h"
#include "processor.h"
#include "ucall_common.h"

#define MAX_VLENB 256
#define OLD_PATTERN 0x5d

static unsigned char old_source[MAX_VLENB] __aligned(64);
static unsigned char new_observed[MAX_VLENB] __aligned(64);

static void vector_load(const void *source, unsigned long vlenb)
{
	asm volatile(".option push\n"
		".option arch, +v\n"
		"vsetvli zero, %1, e8, m1, ta, ma\n"
		"vle8.v v0, (%0)\n"
		".option pop\n"
		:
		: "r"(source), "r"(vlenb)
		: "memory");
}

static void vector_store(void *destination, unsigned long vlenb)
{
	asm volatile(".option push\n"
		".option arch, +v\n"
		"vsetvli zero, %1, e8, m1, ta, ma\n"
		"vse8.v v0, (%0)\n"
		".option pop\n"
		:
		: "r"(destination), "r"(vlenb)
		: "memory");
}

static void old_guest(void)
{
	unsigned long i, vlenb;

	csr_set(CSR_SSTATUS, SR_VS_INITIAL);
	vlenb = csr_read(CSR_VLENB);
	GUEST_ASSERT(vlenb && vlenb <= MAX_VLENB);
	for (i = 0; i < vlenb; i++)
		old_source[i] = OLD_PATTERN;
	vector_load(old_source, vlenb);
	GUEST_DONE();
}

static void new_guest(void)
{
	unsigned long i, vlenb;

	csr_set(CSR_SSTATUS, SR_VS_INITIAL);
	vlenb = csr_read(CSR_VLENB);
	GUEST_ASSERT(vlenb && vlenb <= MAX_VLENB);
	vector_store(new_observed, vlenb);
	for (i = 0; i < vlenb; i++)
		GUEST_ASSERT_EQ(new_observed[i], 0);
	GUEST_DONE();
}

static void pin_to_one_cpu(void)
{
	cpu_set_t allowed, pinned;
	int cpu;

	kvm_sched_getaffinity(0, sizeof(allowed), &allowed);
	for (cpu = 0; cpu < CPU_SETSIZE; cpu++) {
		if (CPU_ISSET(cpu, &allowed))
			break;
	}
	TEST_ASSERT(cpu < CPU_SETSIZE, "no CPU available");

	CPU_ZERO(&pinned);
	CPU_SET(cpu, &pinned);
	kvm_sched_setaffinity(0, sizeof(pinned), &pinned);
}

static void run_to_done(struct kvm_vcpu *vcpu)
{
	struct ucall uc;
	u64 cmd;

	vcpu_run(vcpu);
	cmd = get_ucall(vcpu, &uc);
	if (cmd == UCALL_ABORT)
		REPORT_GUEST_ASSERT(uc);
	TEST_ASSERT_EQ(cmd, UCALL_DONE);
}

static struct kvm_vm *create_vector_vm(struct kvm_vcpu **vcpu,
				       void (*guest_code)(void))
{
	struct kvm_vm *vm;

	vm = vm_create_with_one_vcpu(vcpu, guest_code);
	TEST_REQUIRE(__vcpu_has_isa_ext(*vcpu, KVM_RISCV_ISA_EXT_V));
	vm_init_vector_tables(vm);
	vcpu_init_vector_tables(*vcpu);
	return vm;
}

int main(void)
{
	struct kvm_vm *old_vm, *new_vm;
	struct kvm_vcpu *old_vcpu, *new_vcpu;

	pin_to_one_cpu();
	old_vm = create_vector_vm(&old_vcpu, old_guest);
	new_vm = create_vector_vm(&new_vcpu, new_guest);

	run_to_done(old_vcpu);
	kvm_vm_free(old_vm);

	run_to_done(new_vcpu);
	kvm_vm_free(new_vm);

	pr_info("Vector owner lifetime test passed\n");
	return 0;
}
