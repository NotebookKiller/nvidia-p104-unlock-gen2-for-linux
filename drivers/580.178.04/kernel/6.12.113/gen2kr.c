// SPDX-License-Identifier: GPL-2.0
/*
 * gen2kr.c -- a kretprobe intercepting the tail of nvidia.ko's probe, pushing the PCIe
 *             link to Gen2
 *
 * Evidence (measured in reports/183 N194):
 *   - During probe the driver **only rewrites 0x8C040.SPEED (1->2)** and never touches TLS
 *   - With the driver absent, TLS=2 survived 5 consecutive retrain rounds (0/5)
 *     => the driver actively writes it
 *   - Reference implementation ref/cmpunlocker/driver/patches/pcie-gen2-probe-retrain.patch
 *     hooks this at the tail of nv_pci_probe and **uses plain writel throughout, no SEC2**
 *
 * ★ Key constraint (learned the hard way):
 *   The kretprobe handler runs in atomic context -- it must not msleep or ioremap (which sleeps).
 *   The first attempt did everything in the handler and triggered "BUG: scheduling while atomic".
 *   Now the handler only does schedule_delayed_work; the real work happens in a workqueue.
 *
 * ★ Multi-GPU adaptation (2026-11-13, this server: 3 × P104-100 under load):
 *   The original targeted exactly one GPU -- pci_get_device() always returns the FIRST P104
 *   in PCI order, so pushes aimed at 0000:21:00.0 / 0000:27:00.0 landed on 04:00.0 by mistake.
 *   Now every P104 is tracked in a per-device table:
 *   - the kretprobe's entry handler captures WHICH device was probed (nv_pci_probe's first
 *     argument) and each device is pushed exactly once per module load (the old one-shot
 *     `triggered` flag, per device);
 *   - push_fn processes the queued devices sequentially in one work item -- one link trains
 *     at a time, never several;
 *   - the guard walks the whole table each round but only touches devices whose declaration
 *     is unlocked (CAP2 latched 0x0006) and whose TLS is not the dirty 3 -- a factory device
 *     is never written by the guard, and the gate is stateless, so devices pushed by a
 *     previous module load stay covered after a re-insmod;
 *   - BAR0 of every device is pre-mapped at init (the old single `early_bar`), so the atomic
 *     fast path still writes through a sleeping-free mapping.
 *   The push sequence, register writes, timing constants and dmesg lines are byte-for-byte
 *   the validated ones; only the targeting changed.
 *
 * Sequence (following the reference patch, adapted for Pascal):
 *   ① Unlock declaration: XP3G_OVR0/3 + VAL0/3 + 0x8841C + 0x88610
 *   ② Clear 0x8C2C0 bit2 (DIS_G2)
 *   ③ 0x8C040 SPEED=1 (★ Pascal encoding 1=5GT/s; Ampere is 2) -- never send COMMIT
 *   ④ 0x8872C = 6
 *   ⑤ msleep(50) -> TLS=5GT on both ends -> Retrain from the root port
 *   ⑥ Poll LNKSTA up to 20×100ms
 *   ⑦ Then guard for 30×100ms, pushing SPEED back to 1 (the driver may rewrite it asynchronously)
 */
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/ptrace.h>
#include <linux/pci.h>
#include <linux/pci_regs.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/workqueue.h>
#include <linux/fs.h>
#include <linux/file.h>

#define NV_VENDOR   0x10de
#define NV_DEV_P104 0x1b87

#define OFF_XP3G_OVR0  0x8E110
#define OFF_XP3G_OVR3  0x8E11C
#define OFF_XP3G_VAL0  0x8E120
#define OFF_XP3G_VAL3  0x8E12C
#define OFF_CONFIG     0x8841C   /* PRIV_MISC_1 */
#define OFF_VSEC       0x88610   /* VSEC_HIERARCHY */
#define OFF_CAP2       0x880A4   /* LINK_CAP2 mirror */
#define OFF_LNKCTL2    0x880A8   /* LNKCTL2 mirror, TLS=bits[3:0] */
#define OFF_LTSSM      0x8872C   /* XVE_OVR */
#define OFF_LINKCFG0   0x8C040   /* LINK_CONFIG_0 */
#define OFF_CYA        0x8C2C0   /* CYA_0, bit2 = DIS_G2 */
#define BAR0_LEN       0x90000

static int guard_rounds = 0;     /* 0 = resident; >0 = guard only this many rounds (100ms each) */
module_param(guard_rounds, int, 0644);
MODULE_PARM_DESC(guard_rounds, "guard rounds; 0=resident (default)");

static struct kretprobe krp;

/*
 * ★ Per-device state (multi-GPU adaptation, 2026-11-13):
 *   The original code tracked exactly one GPU -- pci_get_device() always returns the FIRST
 *   P104 in PCI order, so a push aimed at 0000:21:00.0 / 0000:27:00.0 landed on 04:00.0 by
 *   mistake. Now every P104 in the system gets one entry:
 *   - `bar` is pre-mapped at init (the old `early_bar`), so the atomic fast path still
 *     writes without sleeping;
 *   - `pushed` is the old one-shot `triggered` flag, per device;
 *   - the guard state below used to be file-global -- it is per device now.
 */
#define GK_MAX_DEVS 8

struct gk_dev {
    struct pci_dev *gpu;            /* reference held until module exit */
    void __iomem *bar;              /* pre-mapped BAR0, used directly in the handler (no sleeping) */
    bool pushed;                    /* one-shot per device: this module load already pushed it */
    bool pending;                   /* queued for the push workqueue */
    bool tls_bad_logged;            /* suppress repeat warnings of the TLS=3 dirty state */
    int guard_left;                 /* per-device guard rounds (finite mode) */
    unsigned long last_retrain_jiffies;
    /*
     * ★ Timestamp of the last "push SPEED back".
     *   Iron rule (reports/186 #1): after writing SPEED you must wait >=3s before retraining,
     *   or the retrain is wasted (millisecond-scale retrains can even deadlock).
     *   Measured: retraining within 1 second after the guard pushed SPEED back left LNKSTA at 1041.
     */
    unsigned long last_speed_fix_jiffies;
    unsigned long stage_start_jiffies;  /* timestamp of stage0, used to compute stage_gap_ms */
    unsigned long last_attempt_jiffies; /* timestamp of the last full attempt (stage0) */
    int retrain_stage;
    int low_streak;                 /* consecutive Gen1 reads (debounce counter) */
    bool bad_read_logged;           /* suppress repeat warnings of "read 0xffffffff" */
};

static struct gk_dev gk_devs[GK_MAX_DEVS];
static int gk_n;                    /* P104s found at init */

/* kretprobe instance data: which device was probed (nv_pci_probe's first argument) */
struct gk_ctx {
    struct pci_dev *pdev;
};

static struct delayed_work gen2_work;
static int pushback_cnt;
static int retrain_cnt;

/* ---------- Safety-constraint parameters (reports/185: an unconstrained guard once
 *            knocked the whole machine over) ---------- */
static int retrain_min_ms = 2000;   /* minimum interval between two full retrain attempts */
module_param(retrain_min_ms, int, 0644);
MODULE_PARM_DESC(retrain_min_ms, "min interval between retrain attempts in ms, default 2000; 0=unlimited (dangerous)");

/*
 * ★ Interval between stage0 (write 0x8872C=6) and stage1 (root-port Retrain) (reports/196)
 *
 * This parameter was previously crudely reused for retrain_min_ms, forcing a 2-second
 * gap between stages. Measured evidence: `push_fn` succeeds in one shot with msleep(50)
 * (LNKSTA=1042 within 104ms), while the guard waiting 2 seconds before Retrain failed
 * 4 consecutive rounds. Moving this interval to 150ms improved recovery from 9.59s to 5.31s.
 *
 * It cannot be 0: after writing 0x8872C=6 the hardware needs a moment to start training;
 * an immediate Retrain would interrupt it (push also waits 50ms before Retraining).
 */
static int stage_gap_ms = 150;
module_param(stage_gap_ms, int, 0644);
MODULE_PARM_DESC(stage_gap_ms, "stage0->stage1 interval in ms, default 150 (mimics push_fn's 50ms + margin)");

static int debounce_cnt = 3;        /* how many consecutive Gen1 reads before retraining */
module_param(debounce_cnt, int, 0644);
MODULE_PARM_DESC(debounce_cnt, "retrain debounce count, default 3 (3x200ms=600ms; originally 10)");

static int guard_period_ms = 200;   /* guard period, default 200ms (originally 100ms) */

/*
 * Whether retraining is allowed while the GPU is busy.
 *   Default 1 (allowed) -- evidence: the reports/184 old guard had no busy check and
 *   retrained during CUDA runs anyway; bandwidth reached 1.56 with Xid=0, while
 *   "knocked the machine over" was disproven (reports/185 §5 -- it was actually an S3 sleep).
 *   Set 0 for the conservative path: while busy, only push SPEED back and skip retraining
 *   (measured: bandwidth then drops to 0.78).
 */
/*
 * ★ How long after pushing SPEED back before retraining is allowed (lowered per reports/197)
 *
 * This value was originally 3000, from the reports/186 recipe "⑤ write SPEED → ⑥ wait >=3s
 * then Retrain". Measured sweep (tools/sweep-settle.sh, one real "downgrade->recovery" per value):
 *     3000ms -> 5.63s recovery      1500ms -> 4.33s
 *      800ms -> 3.63s              500ms -> 3.43s      300ms -> 3.22s
 * All OK, never a lost card. The benefit clearly diminishes after 800ms (the bottleneck shifts to
 * the ~1.8s physical latency of Retrain taking effect + debounce), so 800 was chosen with 2.6x
 * margin instead of the more aggressive 300.
 *
 * ⚠ It must not go down to millisecond scale: reports/186 iron rule #1 -- retraining immediately
 * after writing SPEED deadlocks the link.
 */
static int speed_settle_ms = 800;
module_param(speed_settle_ms, int, 0644);
MODULE_PARM_DESC(speed_settle_ms, "ms to wait after pushing SPEED back before retraining is allowed, default 800");

static int allow_busy_retrain = 1;
module_param(allow_busy_retrain, int, 0644);
MODULE_PARM_DESC(allow_busy_retrain, "1=also retrain while the GPU is busy (default); 0=skip while busy");
module_param(guard_period_ms, int, 0644);
MODULE_PARM_DESC(guard_period_ms, "guard period in ms, default 200");

/* ---------- Guard state: per device since the multi-GPU adaptation (struct gk_dev) ---------- */


/*
 * Is a process currently using the GPU?
 *
 * ★ Not using find_module(): Linux 6.12 no longer exports that symbol (modpost reported it
 *   undefined in practice). Instead, read /sys/module/nvidia/refcnt directly -- depends on
 *   no kernel API at all, the most robust option.
 *
 * Rule: a refcnt above the "baseline" counts as busy.
 *   The baseline is sampled at module init (nobody has started using the GPU yet).
 *   Resident nvidia_uvm/nvidia_modeset hold one reference each, so the check must be
 *   "above baseline" rather than ">0".
 *
 * Conservative: if unreadable, return true (treat as busy) -- better to skip the fix than
 * to knock the card over.
 */
static int nvidia_ref_baseline = -1;

static int read_nvidia_refcnt(void)
{
    struct file *f;
    char buf[16] = {0};
    loff_t pos = 0;
    ssize_t n;
    int val;

    f = filp_open("/sys/module/nvidia/refcnt", O_RDONLY, 0);
    if (IS_ERR(f))
        return -1;
    n = kernel_read(f, buf, sizeof(buf) - 1, &pos);
    filp_close(f, NULL);
    if (n <= 0)
        return -1;
    if (kstrtoint(buf, 10, &val))
        return -1;
    return val;
}

static bool gpu_busy(void)
{
    int refs = read_nvidia_refcnt();

    if (refs < 0)
        return true;                 /* unreadable -> conservatively treat as busy */

    if (nvidia_ref_baseline < 0) {
        nvidia_ref_baseline = refs;
        return false;
    }
    return refs > nvidia_ref_baseline;
}

static bool guard_enabled = true;
module_param(guard_enabled, bool, 0644);
MODULE_PARM_DESC(guard_enabled, "master switch; 0=the guard does nothing at all (only the initial push)");

/*
 * ★ The two retrain steps (reports/186 recipe, interval corrected in reports/196):
 *     Step 1: write 0x8872C = 6   (triggers LTSSM training, asynchronous)
 *     Step 2: Retrain from the root port (so the negotiation actually happens)
 *
 *   Step 2 alone measured ineffective: the old guard retrained 16 times, LNKSTA stayed 1041.
 *
 *   ★ But the interval between the two steps is **not 3 seconds** (corrected in reports/196):
 *     push_fn succeeded in one shot with msleep(50) (LNKSTA=1042 within 104ms);
 *     the early guard used retrain_min_ms (2000) as the stage interval and failed 4 rounds straight.
 *     Now a separate stage_gap_ms (150) is used, and stage1 no longer re-enters the debounce path.
 */
static void gk_guard_one(struct gk_dev *d)
{
    struct pci_dev *gpu = d->gpu;
    struct pci_dev *up;
    void __iomem *bar = d->bar;
    u32 v, lk;
    u16 st = 0;
    bool low;

    if (!bar)
        return;

    v = readl(bar + OFF_CAP2);
    if (v == 0xFFFFFFFFu)
        return;

    /*
     * ★ Multi-GPU gate: only guard a device whose declaration is unlocked -- CAP2 latches
     *   0x0006 after a successful push (or an equivalent user-space unlock). A factory
     *   device (CAP2 == 0x0002) must never be written by the guard, and a stuck device is
     *   exactly what reports/198 concluded only a full reboot can cure. The gate is
     *   stateless on purpose: it also keeps covering devices pushed by a PREVIOUS module
     *   load (e.g. after push.sh's rmmod/insmod cycle for the next GPU).
     */
    if (v != 0x00000006u)
        return;

    /* ★ TLS=3 is the dirty state only a cold boot recovers from -- never touch it
     *   (read+skip only, no writes, so this check cannot make anything worse) */
    v = readl(bar + OFF_LNKCTL2);
    if ((v & 0xF) == 3) {
        if (!d->tls_bad_logged) {
            pr_warn("gen2kr: [guard] %s sits in the dirty TLS=3 state; refusing to touch it (a full reboot is the only cure)\n",
                    dev_name(&gpu->dev));
            d->tls_bad_logged = true;
        }
        return;
    }

    /* ① Push SPEED back (a tiny pure-MMIO write, no side effects, safe to do every round) */
    lk = readl(bar + OFF_LINKCFG0);
    /*
     * ★★★ Triple check, all three mandatory (reports/196 -- this was the root cause of a
     *      real lost card)
     *
     * We used to only check CAP2 != 0xffffffff and confidently push SPEED back. But LINKCFG0
     * itself can also transiently read 0xffffffff during a link retrain, in which case:
     *     0xFFFFFFFF & ~0x000C0000 = 0xFFF3FFFF
     *     0xFFF3FFFF | (1 << 18)   = 0xFFF7FFFF
     *                                    ^ bit0 = 1 = COMMIT -> guaranteed lost card!
     * Measured cost: the device went into C. ZOMBIE; only a full reboot helps.
     *
     * So: ① it must not be 0xffffffff ② bit0 (COMMIT) must be 0 ③ only then look at the
     * SPEED bits
     */
    if (lk == 0xFFFFFFFFu) {
        if (!d->bad_read_logged) {
            pr_warn("gen2kr: [guard] LINKCFG0 read 0xffffffff, skipping this round's push-back\n");
            d->bad_read_logged = true;
        }
        return;
    }
    d->bad_read_logged = false;
    if ((lk & 1u) != 0) {
        /* The COMMIT bit is set -- never write back on top of it, only warn */
        pr_warn_ratelimited("gen2kr: [guard] LINKCFG0 bit0(COMMIT)=1, refusing to write back (lk=%08x)\n", lk);
        return;
    }
    if (((lk >> 18) & 0x3) != 1) {
        pr_info("gen2kr: [guard] device %s\n", dev_name(&gpu->dev));
        writel((lk & ~0x000C0000u) | (1u << 18), bar + OFF_LINKCFG0);
        d->last_speed_fix_jiffies = jiffies;
        pushback_cnt++;
        pr_info_ratelimited("gen2kr: [guard] SPEED pushed back to 1 (count %d, was %08x)\n",
                            pushback_cnt, lk);
    }

    /* ② Has the link really dropped to Gen1 -- only consider a retrain when "stably low" */
    if (pcie_capability_read_word(gpu, PCI_EXP_LNKSTA, &st))
        return;
    low = (st & PCI_EXP_LNKSTA_CLS) < PCI_EXP_LNKSTA_CLS_5_0GB;

    if (!low) {
        d->low_streak = 0;          /* already fine, reset */
        d->retrain_stage = 0;       /* ★ also reset the stage so the next drop does not jump straight to Retrain */
        return;
    }
    d->low_streak++;

    if (!guard_enabled)
        return;

    /* ============ stage 1: second step of the same attempt, no re-debouncing ============ */
    if (d->retrain_stage == 1) {
        u16 ctl = 0;

        /* Only wait stage_gap_ms (mimicking push_fn's msleep(50) + margin) */
        if (time_before(jiffies,
                        d->stage_start_jiffies + msecs_to_jiffies(stage_gap_ms)))
            return;

        up = pci_upstream_bridge(gpu);
        if (up && !pcie_capability_read_word(up, PCI_EXP_LNKCTL, &ctl)) {
            pr_info("gen2kr: [guard] device %s\n", dev_name(&gpu->dev));
            pcie_capability_write_word(up, PCI_EXP_LNKCTL,
                                       ctl | PCI_EXP_LNKCTL_RL);
            pr_info("gen2kr: [guard] root-port Retrain (LNKSTA=%04x, stage interval %dms)\n",
                    st, stage_gap_ms);
        }
        d->retrain_stage = 0;
        d->low_streak = 0;
        return;
    }

    /* ============ stage 0: the full triple gate is required ============ */
    if (d->low_streak < debounce_cnt)
        return;

    /*
     * ★ We once tried adding "precondition self-healing" here (TLS / declaration), and rolled
     *    it back (reports/198 §failed experiment)
     *
     * The idea: after a driver reload the endpoint TLS is clamped back to 1 and the
     * declaration resets to Gen1, so the guard would rewrite TLS=2 here and re-unlock the
     * declaration.
     * Measured: **ineffective**.
     *   - Right after writing TLS 2 it reads back 1 (`endpoint TLS2 0001 -> 0002` repeated
     *     every 600ms, and the next round read 0001 again) -- the driver clamps it; we lose
     *     the race
     *   - After unlocking the declaration CAP2 still read 0x0002 (CAP2 only latches after
     *     0x8872C=6, and even with training triggered it could not be rescued)
     *   - 6 rounds of unbind/bind + 9 unlock attempts, the link stayed LNKSTA=1 throughout
     *   - And hammering the config space every 600ms is risky in itself
     * => rolled back. The right fix is a full reboot to a clean state (see the reports/198
     *    conclusion).
     */
    if (time_before(jiffies,
                    d->last_attempt_jiffies + msecs_to_jiffies(retrain_min_ms)))
        return;
    /* ★ After pushing SPEED back you must wait long enough, or the retrain is wasted
     *   (reports/186 iron rule #1) */
    if (time_before(jiffies,
                    d->last_speed_fix_jiffies + msecs_to_jiffies(speed_settle_ms)))
        return;
    if (!allow_busy_retrain && gpu_busy()) {
        pr_info_ratelimited("gen2kr: [guard] GPU busy, skipping the retrain this round\n");
        return;
    }

    /* Step 1: trigger LTSSM training */
    pr_info("gen2kr: [guard] device %s\n", dev_name(&gpu->dev));
    writel(0x00000006, bar + OFF_LTSSM);
    d->retrain_stage = 1;
    d->stage_start_jiffies = jiffies;
    d->last_attempt_jiffies = jiffies;
    d->last_retrain_jiffies = jiffies;
    d->low_streak = 0;
    retrain_cnt++;
    pr_info("gen2kr: [guard] triggered training 0x8872C=6 (global count %d, LNKSTA=%04x)\n",
            retrain_cnt, st);
}

static void guard_fn(struct work_struct *w)
{
    int i;
    bool alive = false;

    /* One shared guard walks every tracked device; each device has its own
     * finite-mode budget (d->guard_left). */
    for (i = 0; i < gk_n; i++) {
        struct gk_dev *d = &gk_devs[i];

        if (guard_rounds > 0) {
            if (d->guard_left == 0)
                continue;               /* this device's guard has finished */
            d->guard_left--;
        }
        alive = true;

        gk_guard_one(d);
    }

    if (guard_rounds > 0 && !alive) {
        pr_info("gen2kr: guard finished, %d SPEED push-backs and %d retrains in total\n",
                pushback_cnt, retrain_cnt);
        return;
    }
    schedule_delayed_work(&gen2_work, msecs_to_jiffies(guard_period_ms));
}

/* ---------- Phase 1: the actual Gen2 push (in a workqueue, may sleep) ---------- */
static void gk_push_one(struct gk_dev *d)
{
    struct pci_dev *gpu = d->gpu;
    struct pci_dev *up;
    void __iomem *bar = d->bar;
    u32 v;
    u16 ctl2, ctl, sta = 0;
    int i;

    if (!bar) {
        pr_err("gen2kr: ioremap failed\n");
        return;
    }

    pr_info("gen2kr: [push] device %s\n", dev_name(&gpu->dev));
    pr_info("gen2kr: [push] start cap2=%08x config=%08x lnkcfg0=%08x\n",
            readl(bar + OFF_CAP2), readl(bar + OFF_CONFIG),
            readl(bar + OFF_LINKCFG0));

    /* ① Unlock the declaration */
    writel(0x00000001, bar + OFF_XP3G_OVR0);
    writel(0x00000004, bar + OFF_XP3G_OVR3);
    writel(0x00000000, bar + OFF_XP3G_VAL0);
    writel(0x00200000, bar + OFF_XP3G_VAL3);
    v = readl(bar + OFF_CONFIG);
    writel((v | (1u << 11) | (1u << 13) | (1u << 15)) & ~((1u << 12) | (1u << 14)),
           bar + OFF_CONFIG);
    v = readl(bar + OFF_VSEC);
    writel((v & ~(1u << 12)) | 1u, bar + OFF_VSEC);

    /* ② Clear DIS_G2 */
    v = readl(bar + OFF_CYA);
    writel(v & ~(1u << 2), bar + OFF_CYA);

    /* ③ SPEED = 1 (Pascal), never send COMMIT */
    /*
     * ★ The same defense line as the guard (reports/196): deriving from 0xffffffff would carry
     *    COMMIT along. The chance of reading ffffffff during push is lower, but if it happens
     *    it guarantees a lost card -- so the check is mandatory.
     */
    v = readl(bar + OFF_LINKCFG0);
    if (v == 0xFFFFFFFFu || (v & 1u) != 0) {
        pr_err("gen2kr: [push] LINKCFG0=%08x not trustworthy (ffffffff or COMMIT=1), skipping the SPEED write\n", v);
    } else {
        writel((v & ~0x000C0000u) | (1u << 18), bar + OFF_LINKCFG0);
    }

    /* ④ XVE_OVR */
    writel(0x00000006, bar + OFF_LTSSM);

    pr_info("gen2kr: [push] after writes cap2=%08x config=%08x lnkcfg0=%08x cya=%08x\n",
            readl(bar + OFF_CAP2), readl(bar + OFF_CONFIG),
            readl(bar + OFF_LINKCFG0), readl(bar + OFF_CYA));

    /* The reference patch's msleep(50) */
    msleep(50);

    /* ⑤ TLS=5GT on both ends, root-port Retrain */
    if (!pcie_capability_read_word(gpu, PCI_EXP_LNKCTL2, &ctl2)) {
        pcie_capability_write_word(gpu, PCI_EXP_LNKCTL2,
                                   (ctl2 & ~PCI_EXP_LNKCTL2_TLS) |
                                   PCI_EXP_LNKCTL2_TLS_5_0GT);
        pr_info("gen2kr: endpoint TLS2 %04x -> %04x\n", ctl2,
                (ctl2 & ~PCI_EXP_LNKCTL2_TLS) | PCI_EXP_LNKCTL2_TLS_5_0GT);
    }

    up = pci_upstream_bridge(gpu);
    if (up) {
        if (!pcie_capability_read_word(up, PCI_EXP_LNKCTL2, &ctl2)) {
            pcie_capability_write_word(up, PCI_EXP_LNKCTL2,
                                       (ctl2 & ~PCI_EXP_LNKCTL2_TLS) |
                                       PCI_EXP_LNKCTL2_TLS_5_0GT);
            pr_info("gen2kr: root-port TLS2 %04x -> %04x\n", ctl2,
                    (ctl2 & ~PCI_EXP_LNKCTL2_TLS) | PCI_EXP_LNKCTL2_TLS_5_0GT);
        }
        if (!pcie_capability_read_word(up, PCI_EXP_LNKCTL, &ctl)) {
            pcie_capability_write_word(up, PCI_EXP_LNKCTL, ctl | PCI_EXP_LNKCTL_RL);
            pr_info("gen2kr: root-port LNKCTL %04x -> %04x (Retrain)\n",
                    ctl, ctl | PCI_EXP_LNKCTL_RL);
        }
    }

    /* ⑥ Poll */
    for (i = 0; i < 20; i++) {
        msleep(100);
        if (pcie_capability_read_word(gpu, PCI_EXP_LNKSTA, &sta))
            continue;
        if ((sta & PCI_EXP_LNKSTA_CLS) >= PCI_EXP_LNKSTA_CLS_5_0GB) {
            pr_info("gen2kr: ★ SUCCESS Gen%u LNKSTA=%04x (on attempt %d)\n",
                    sta & PCI_EXP_LNKSTA_CLS, sta, i + 1);
            break;
        }
    }
    if (i == 20)
        pr_warn("gen2kr: no speed-up, LNKSTA=%04x\n", sta);

    /* ⑦ Arm this device's guard state (the shared guard work is (re)started by push_fn) */
    d->last_retrain_jiffies = jiffies;
    d->last_attempt_jiffies = jiffies;
    d->stage_start_jiffies = jiffies;
    d->retrain_stage = 0;
    d->low_streak = 0;
    d->guard_left = (guard_rounds > 0) ? guard_rounds : 1;
}

static void push_fn(struct work_struct *w)
{
    int i;
    bool pushed_any = false;

    /* Process the queued devices sequentially -- one link trains at a time, never several. */
    for (i = 0; i < gk_n; i++) {
        struct gk_dev *d = &gk_devs[i];

        if (!d->pending)
            continue;
        d->pending = false;
        gk_push_one(d);
        pushed_any = true;
    }

    if (pushed_any)
        schedule_delayed_work(&gen2_work, msecs_to_jiffies(100));
}

static DECLARE_WORK(push_work, push_fn);

static struct gk_dev *gk_find(struct pci_dev *pdev)
{
    int i;

    for (i = 0; i < gk_n; i++)
        if (gk_devs[i].gpu == pdev)
            return &gk_devs[i];
    return NULL;
}

/* ---------- kretprobe handlers: schedule only, do nothing themselves ---------- */

/* ★ The entry handler records WHICH device was probed (nv_pci_probe's first argument) --
 *   that is the whole point of the multi-GPU adaptation: the return handler used to blindly
 *   target the first P104 in PCI order. */
static int gk_entry_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    ((struct gk_ctx *)ri->data)->pdev =
        (struct pci_dev *)regs_get_kernel_argument(regs, 0);
    return 0;
}

static int ret_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
    struct gk_ctx *ctx = (struct gk_ctx *)ri->data;
    struct gk_dev *d;
    u32 lk;

    d = gk_find(ctx->pdev);
    if (!d) {
        if (ctx->pdev &&
            ctx->pdev->vendor == NV_VENDOR && ctx->pdev->device == NV_DEV_P104)
            pr_warn_ratelimited("gen2kr: P104 %s probed but not tracked (table full); skipping\n",
                                dev_name(&ctx->pdev->dev));
        return 0;
    }
    if (d->pushed)
        return 0;
    d->pushed = true;

    pr_info("gen2kr: probe returned for %s\n", dev_name(&d->gpu->dev));

    /* ★ Ultra-fast path: write SPEED directly through the pre-mapped BAR0 (writel only,
     *   no sleeping)
     *   Measured: the workqueue-only version lands a few ticks late and misses the window
     *   right after the probe returns; doing it directly in atomic context actually
     *   succeeded once (LNKSTA=1042). */
    if (d->bar) {
        lk = readl(d->bar + OFF_LINKCFG0);
        /* ★ The COMMIT guard is equally mandatory here (reports/196): checking for ffffffff
         *   alone is not enough -- if lk's bit0 is already 1, pushing SPEED back would write
         *   COMMIT along with it -> lost card */
        if (lk != 0xFFFFFFFFu && (lk & 1u) == 0) {
            writel((lk & ~0x000C0000u) | (1u << 18), d->bar + OFF_LINKCFG0);
            writel(0x00000006, d->bar + OFF_LTSSM);
            pr_info("gen2kr: [fast] wrote SPEED=1 directly, %08x -> %08x\n",
                    lk, readl(d->bar + OFF_LINKCFG0));
        } else {
            pr_warn("gen2kr: [fast] LINKCFG0=%08x not trustworthy, skipping the direct write (handing over to the workqueue)\n", lk);
        }
    }

    d->pending = true;
    schedule_work(&push_work);
    pr_info("gen2kr: nv_pci_probe has returned; retrain queued\n");
    return 0;
}

static void gk_release_devices(void)
{
    int i;

    for (i = 0; i < gk_n; i++) {
        if (gk_devs[i].bar)
            iounmap(gk_devs[i].bar);
        if (gk_devs[i].gpu)
            pci_dev_put(gk_devs[i].gpu);
    }
    gk_n = 0;
}

static int __init gen2kr_init(void)
{
    int ret;
    struct pci_dev *from = NULL;
    struct pci_dev *dev;

    memset(&krp, 0, sizeof(krp));
    krp.kp.symbol_name = "nv_pci_probe";
    krp.handler = ret_handler;
    krp.entry_handler = gk_entry_handler;
    krp.data_size = sizeof(struct gk_ctx);
    krp.maxactive = 4;

    INIT_DELAYED_WORK(&gen2_work, guard_fn);

    /* Sample nvidia.ko's module reference baseline (used by the gpu_busy rule) */
    {
        int rc = read_nvidia_refcnt();
        if (rc >= 0) {
            nvidia_ref_baseline = rc;
            pr_info("gen2kr: nvidia refcnt baseline = %d\n", rc);
        } else {
            pr_warn("gen2kr: cannot read /sys/module/nvidia/refcnt; gpu_busy will always be true\n");
        }
    }

    /* Build the per-device table: track EVERY P104, not just the first one. Pre-map each
     * BAR0 so the atomic fast path can write without sleeping. */
    while ((dev = pci_get_device(NV_VENDOR, NV_DEV_P104, from)) != NULL) {
        struct gk_dev *d;

        if (gk_n >= GK_MAX_DEVS) {
            pr_warn("gen2kr: more than %d P104s present, ignoring the rest\n", GK_MAX_DEVS);
            pci_dev_put(dev);
            break;
        }

        d = &gk_devs[gk_n++];
        d->gpu = dev;      /* the table keeps this reference until module exit */
        d->bar = ioremap(pci_resource_start(dev, 0), BAR0_LEN);
        if (!d->bar)
            pr_warn("gen2kr: BAR0 ioremap failed for %s; its push will be skipped\n",
                    dev_name(&dev->dev));
        pr_info("gen2kr: tracking %s\n", dev_name(&dev->dev));
        pr_info("gen2kr: pre-mapped BAR0 @ %llx -> %px\n",
                (unsigned long long)pci_resource_start(dev, 0), d->bar);

        /* pci_get_device() consumes the reference of `from`, so pass a clone and keep
         * the found device's own reference in the table */
        from = pci_dev_get(dev);
    }
    if (gk_n == 0)
        pr_warn("gen2kr: P104 not found\n");

    ret = register_kretprobe(&krp);
    if (ret) {
        pr_err("gen2kr: register_kretprobe failed %d\n", ret);
        gk_release_devices();
        return ret;
    }
    pr_info("gen2kr: kretprobe attached on nv_pci_probe\n");
    return 0;
}

static void __exit gen2kr_exit(void)
{
    unregister_kretprobe(&krp);
    cancel_work_sync(&push_work);
    cancel_delayed_work_sync(&gen2_work);
    gk_release_devices();
    pr_info("gen2kr: unloaded\n");
}

module_init(gen2kr_init);
module_exit(gen2kr_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Push NVIDIA P104-100 PCIe links to Gen2 after probe");
