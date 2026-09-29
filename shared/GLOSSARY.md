## ADSC (Acko Drive Service Centre)

This is the most dangerous ambiguous term in the platform. **"ADSC" alone never determines the pod.**

| What the user means | Correct pod | How to tell |
|---|---|---|
| Workshop business performance — orders placed, NPS score, revenue, repeat customers, demand funnel | AVA | Signal words: orders, NPS, revenue, repeat, garage, invoice, repair, conversion |
| Field operations — vehicle pickup/drop tasks, ServiceOS agents, slot availability, TAT, task completion | FIA | Signal words: pickup, drop, agent, slot, task, ServiceOS, TAT, field engineer, completed tasks |

**Examples:**
- "How many ADSC orders in August?" → AVA
- "How many pickups completed in ADSC in August?" → FIA
- "ADSC NPS for August?" → AVA  
- "ADSC agent TAT breach?" → FIA
- "ADSC demand funnel?" → AVA
- "ADSC slot availability?" → FIA

When the question says "ADSC" with no other clear signal — ask which one before routing.

# Shared Glossary — Same Word, Different Meaning

Terms that appear in multiple pods but have different definitions in each.
Every pod analyst must read this before answering a question that uses these terms,
to ensure they use their pod-specific definition and not a generic assumption.

The orchestrator uses this table to trigger disambiguation when a cross-pod question
uses one of these terms without specifying a pod.

---

## claim

| Pod | What "claim" means |
|---|---|
| **ACE (Escalation)** | An insurance claim linked to an escalation ticket. Identified via `total_claim_cnt > 0`. A claim-related escalation is a customer grievance where an active insurance claim exists. |
| **Retail Travel (AVI)** | A travel insurance claim filed after a trip incident (medical, cancellation, baggage loss, etc.). Lives in `DataMigrator.jarvis_claim`. |
| **GIVA (User Growth)** | Not a claim concept — `total_claim_cnt` does not exist in user_growth tables. If a user asks about claims in user growth context, it likely means "how many users with an active claim are in the reachable base" — route to ACE for the claim count and GIVA for the user base. |
| **ADSC (AVA)** | `is_claim_related_order` flag on `fact_adsc_orders` — a repair job where the customer's insurance claim is paying for the repair. Different from a filed claim. |

---

## order

| Pod | What "order" means |
|---|---|
| **ADSC (AVA)** | A workshop repair job. PK = `id` on `fact_adsc_orders`. Valid = status ≠ CANCELLED. |
| **Retail Travel (AVI)** | Does not use "order" — the equivalent concept is a `policy` (policyid). |
| **Auto (not yet built)** | Motor insurance policy sale — would be equivalent to AVI's policy, not ADSC's repair job. |
| **GIVA (User Growth)** | Not an order concept — product events in user_growth_master_agg track payment/entry flags, not orders. |

---

## customer

| Pod | What "customer" means |
|---|---|
| **ADSC (AVA)** | A person who has had at least one valid workshop order. Identified via `phone_hashed` on `adsc_repeat_view_orders_base`. |
| **Retail Travel (AVI)** | A policyholder — identified via `policyid` or `insuredid`. One policyholder can have multiple insured members. |
| **ACE (Escalation)** | The person who raised an escalation ticket. Identified via `phone_hashed`. May or may not be a policyholder. |
| **GIVA (User Growth)** | A user in the D2C app base — identified via `user_id` (hashed). Broader than policyholder: includes vehicle owners who have never bought a policy. |
| **FORA (Fleet RSA)** | The vehicle owner who filed an RSA request. Identified via `phone_hashed`. |

**Rule:** Never use "customer count" as a cross-pod metric without specifying which definition.

---

## TAT (Turnaround Time)

| Pod | Start event | End event | Unit | What it measures |
|---|---|---|---|---|
| **FORA** | `appointment_datetime` (scheduled) | `reach_customer_ts` | Minutes | Time from scheduled RSA appointment to agent arriving at customer |
| **FIA** | `schedule_start_time` | `reach_customer_ts` | Minutes | Time from scheduled ServiceOS task start to agent arriving at customer |
| **ACE** | `created_at` (ticket opened) | Resolution timestamp | Hours | Time from escalation ticket creation to closure |
| **ADSC (AVA)** | Vehicle drop-off timestamp | Vehicle ready for pickup | Hours | Workshop repair turnaround |

**Rule:** When reporting TAT in a cross-pod context, always state the start→end events explicitly.

---

## NPS / satisfaction

| Pod | Instrument | Scale | Population |
|---|---|---|---|
| **ADSC (AVA)** | NPS | 0–10 → Promoter/Passive/Detractor formula | Sampled from completed workshop customers |
| **ACE (Escalation)** | CSAT | 1–5 | Customers whose escalation was resolved |

**Rule:** NPS and CSAT are different instruments. Do not average them or present them on the same axis without explicit labelling.

---

## conversion

| Pod | What it measures | Formula |
|---|---|---|
| **Retail Travel (AVI)** | Funnel stage completion — V2E, E2Q, Q2S, V2S | Users completing a stage / users who entered the prior stage |
| **ADSC (AVA)** | Appointment-to-order conversion | Valid orders with a linked appointment / valid appointments |

**Rule:** "Conversion rate" without a pod label is meaningless. Always specify.

---

## active

| Pod | What "active" means |
|---|---|
| **GIVA (User Growth)** | User opened the app at least once this month (`app_open_flag = 1`). MAU = active users. |
| **ADSC (AVA)** | No "active" concept — ADSC customers are identified by order history, not app activity. |
| **Retail Travel (AVI)** | A policy is "active" if the travel date range is current and policy_status is not cancelled. |
| **FORA** | An RSA task is "active" if `dispatch_status` is not COMPLETED or CANCELLED. |

---

## repeat

| Pod | What "repeat" means |
|---|---|
| **ADSC (AVA)** | Customer who has had more than one valid workshop order (`user_type = '3. Repeat user'` on `adsc_repeat_view_orders_base`). |
| **GIVA (User Growth)** | User who opened the app last month and this month (`app_open_lifecycle_bucket = 'Returning'`). Not the same as a repeat purchaser. |
| **Retail Travel (AVI)** | A renewal policy (policy purchased after a prior policy for the same customer). |

---

## completion

| Pod | What "completion" means |
|---|---|
| **FORA** | `dispatch_status = 'COMPLETED'` — RSA task done, agent reached customer and finished the job. |
| **FIA** | `final_status_corrected = 'DONE'` AND `final_slot_flag = 1` — ServiceOS task slot completed. |
| **ADSC (AVA)** | `status = 'COMPLETED'` on `fact_adsc_appointments` — appointment attended. Different from a valid order. |

---

## new user

| Pod | What "new" means |
|---|---|
| **GIVA (User Growth)** | User opening the app for the first time ever (`app_open_lifecycle_bucket = 'New'`). |
| **ADSC (AVA)** | Customer placing their first-ever ADSC workshop order (`user_type = '1. New user'` on `adsc_repeat_view_orders_base`). |

---

*This glossary is maintained by the platform owner. When a new pod is added, every ambiguous term it introduces must be added here before the pod goes live.*
