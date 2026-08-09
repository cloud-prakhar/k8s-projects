# Beginner Exercises — Project 01

Attempt each before opening [`solutions/`](solutions/). Getting stuck is the lesson.

Assume a working deployment: `./scripts/validate.sh` passes.

---

## Exercise 1 — Scale the web tier

**Task:** scale `task-web` from 2 to 5 replicas — twice, once imperatively and once declaratively.

**Success:** `kubectl get pods -n task-tracker` shows 5 `task-web` Pods Running.

**Hint:** `kubectl scale --help`, and `spec.replicas` in the manifest.

**Think about:** which of the two survives the next `kubectl apply -f`? Why does that matter under GitOps?

---

## Exercise 2 — Find which Pod served you

**Task:** without using the browser, make 10 requests through `task-web` and print only the backend Pod name each
time.

**Success:** you see more than one distinct Pod name.

**Hint:** `/api/info` returns JSON with a `pod` field; `port-forward` to `svc/task-web`.

**Think about:** why isn't the distribution perfectly even? What would happen with a keep-alive HTTP client?

---

## Exercise 3 — Read the config out of a running container

**Task:** print `APP_ENV`, `LOG_LEVEL` and `TASK_API_URL` as the container actually sees them — not from the
manifest, from inside the Pod.

**Success:** three values matching the ConfigMap.

**Hint:** `kubectl exec`.

**Think about:** where did each value come from, and how would you prove it?

---

## Exercise 4 — Change the log level and make it take effect

**Task:** switch `LOG_LEVEL` to `debug` and confirm the API is actually logging every request.

**Success:** `kubectl logs deployment/task-api -n task-tracker` shows per-request debug lines.

**Hint:** editing the ConfigMap alone won't do it. Why not?

**Think about:** what would make this happen automatically on the next config change?

---

## Exercise 5 — Roll back

**Task:** deploy a deliberately bad image tag, watch the rollout stall, then return to the working version — without
editing any YAML.

**Success:** `kubectl get pods` shows all Pods Running on `task-api:1.0.0`.

**Hint:** `kubectl set image`, `kubectl rollout undo`, `kubectl rollout history`.

**Think about:** what did `rollout undo` actually do? Where was the old configuration stored?

---

## Exercise 6 — Delete a Pod and prove self-healing

**Task:** delete one `task-api` Pod and capture evidence that the replacement is a **different object**, not the same
Pod restarted.

**Success:** you can show the name and IP both changed, and that `RESTARTS` is 0 on the new Pod.

**Hint:** `-o wide`, and compare with the `RESTARTS` column after `kill 1` inside a container.

**Think about:** what's the difference between a container restart and a Pod replacement?

---

## Exercise 7 — Namespace hygiene

**Task:** make `kubectl get pods` (with no `-n`) show this project's Pods, then put it back.

**Success:** `kubectl get pods` lists `task-api` and `task-web` Pods.

**Hint:** `kubectl config set-context --current --namespace=…`

**Think about:** why does this repository still write `-n task-tracker` on every command anyway?
