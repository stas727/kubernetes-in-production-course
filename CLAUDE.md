# Module 02 – Security & Policy as Code

Контекст кластера: **`k3d-kip`** (локальный k3d, 1 server + 2 agents, k3s v1.35.5).
Это **один** кластер — разделение между ментором/студентами делается не отдельными
кластерами, а через **namespaces + RBAC**, ровно как это устроено на реальном проде.

Аутентификация в kubeconfig — через **ServiceAccount-токены** (штатный механизм k3s,
`kubectl create token`). Это не "по умолчанию для подов", это обычный способ выдать
доступ человеку в кластере без внешнего IAM/OIDC.

Манифесты — обычные YAML (`kubectl apply -f`), без Helm. Перевод на Helm chart —
отдельное задание Module 03, здесь не делаем.

Всё, что ниже — **план и команды для ручного запуска**. Claude ничего не применяет
в кластер самостоятельно, пока явно не попросишь выполнить конкретный шаг.

---

## Структура репозитория (предлагается)

```
module-02-security/
├── 00-namespaces.yaml
├── 01-service-accounts.yaml
├── 02-rbac.yaml
├── 03-kyverno-readonly-rootfs-audit.yaml
├── 04-kyverno-person-label.yaml
├── kubeconfig/              # сюда складываем сгенерированные kubeconfig (gitignore!)
└── README.md                # как проверить, что всё работает (verification steps)
```

Добавить в `.gitignore`: `module-02-security/kubeconfig/` — токены ServiceAccount
не должны попадать в git.

---

## Шаг 1. Namespaces

Файл `00-namespaces.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: mentor
---
apiVersion: v1
kind: Namespace
metadata:
  name: student01
---
apiVersion: v1
kind: Namespace
metadata:
  name: student02
---
apiVersion: v1
kind: Namespace
metadata:
  name: student03
```

Применить:
```bash
kubectl --context k3d-kip apply -f module-02-security/00-namespaces.yaml
```

`default` namespace уже существует в кластере — отдельно создавать не нужно,
он нужен нам только как цель RO-доступа для student02.

---

## Шаг 2. ServiceAccounts (по одному на человека)

Каждому человеку — один ServiceAccount, живущий в "своём" namespace.
Так и ментор, и все студенты получают identity, привязанную к Kubernetes API,
без создания отдельных кластеров или внешнего IdP.

Файл `01-service-accounts.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mentor
  namespace: mentor
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: student01
  namespace: student01
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: student02
  namespace: student02
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: student03
  namespace: student03
```

Применить:
```bash
kubectl --context k3d-kip apply -f module-02-security/01-service-accounts.yaml
```

---

## Шаг 3. RBAC

Права разбиты на два типа ролей, которые переиспользуются через `ClusterRole`
(шаблон прав) + `RoleBinding` (привязка шаблона к конкретному namespace — это
НЕ даёт прав на весь кластер, `RoleBinding` всегда ограничен namespace, в котором
он создан).

- `ns-read-write` — ClusterRole с правами на create/get/list/watch/update/patch/delete
  для основных namespaced-ресурсов (pods, deployments, services, configmaps, secrets и т.п.)
- `ns-read-only` — ClusterRole с правами только get/list/watch на те же ресурсы

Матрица доступов из задания:

| Кто | mentor ns | student01 ns | student02 ns | student03 ns | default ns |
|---|---|---|---|---|---|
| mentor | - | RW | RW | RW | - |
| student01 | - | RW | - | - | - |
| student02 | - | RO | RW | - | RO |
| student03 | - | - | - | RW | - |

Файл `02-rbac.yaml`:

```yaml
# --- переиспользуемые шаблоны прав (не дают доступа сами по себе без Binding) ---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ns-read-write
rules:
  - apiGroups: ["", "apps", "batch", "networking.k8s.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ns-read-only
rules:
  - apiGroups: ["", "apps", "batch", "networking.k8s.io"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]

# --- mentor: RW в student01, student02, student03 ---
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: mentor-rw
  namespace: student01
subjects:
  - kind: ServiceAccount
    name: mentor
    namespace: mentor
roleRef:
  kind: ClusterRole
  name: ns-read-write
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: mentor-rw
  namespace: student02
subjects:
  - kind: ServiceAccount
    name: mentor
    namespace: mentor
roleRef:
  kind: ClusterRole
  name: ns-read-write
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: mentor-rw
  namespace: student03
subjects:
  - kind: ServiceAccount
    name: mentor
    namespace: mentor
roleRef:
  kind: ClusterRole
  name: ns-read-write
  apiGroup: rbac.authorization.k8s.io

# --- student01: RW только в своём namespace ---
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: student01-rw
  namespace: student01
subjects:
  - kind: ServiceAccount
    name: student01
    namespace: student01
roleRef:
  kind: ClusterRole
  name: ns-read-write
  apiGroup: rbac.authorization.k8s.io

# --- student02: RW в своём namespace, RO в student01 и default ---
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: student02-rw
  namespace: student02
subjects:
  - kind: ServiceAccount
    name: student02
    namespace: student02
roleRef:
  kind: ClusterRole
  name: ns-read-write
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: student02-ro
  namespace: student01
subjects:
  - kind: ServiceAccount
    name: student02
    namespace: student02
roleRef:
  kind: ClusterRole
  name: ns-read-only
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: student02-ro
  namespace: default
subjects:
  - kind: ServiceAccount
    name: student02
    namespace: student02
roleRef:
  kind: ClusterRole
  name: ns-read-only
  apiGroup: rbac.authorization.k8s.io

# --- student03: RW только в своём namespace ---
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: student03-rw
  namespace: student03
subjects:
  - kind: ServiceAccount
    name: student03
    namespace: student03
roleRef:
  kind: ClusterRole
  name: ns-read-write
  apiGroup: rbac.authorization.k8s.io
```

Применить:
```bash
kubectl --context k3d-kip apply -f module-02-security/02-rbac.yaml
```

**Почему это не Cluster Admin:** `ClusterRole` здесь используется только как шаблон
правил (`ns-read-write` / `ns-read-only`), но привязывается он всегда через
`RoleBinding` (не `ClusterRoleBinding`) — а `RoleBinding` действует **только**
в namespace, в котором он создан. Ни ментор, ни студенты не получают доступа к
ресурсам уровня кластера (nodes, PV, другие namespaces, ClusterRoles и т.п.).

---

## Шаг 4. Генерация kubeconfig для каждого пользователя

Для каждого ServiceAccount нужно: достать CA кластера и server URL (из текущего
kubeconfig админа), сгенерировать токен (`kubectl create token`, с ограниченным
сроком действия, например 8760h ~ год — для учебного проекта это ок, долговечность
проще для проверки ментором), собрать отдельный kubeconfig-файл.

Пример для mentor (аналогично для каждого student0N):

```bash
CLUSTER_NAME=k3d-kip
SERVER=$(kubectl --context $CLUSTER_NAME config view --raw -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl --context $CLUSTER_NAME config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

NS=mentor
SA=mentor
TOKEN=$(kubectl --context $CLUSTER_NAME -n $NS create token $SA --duration=8760h)

KUBECONFIG_OUT=module-02-security/kubeconfig/${SA}.kubeconfig

kubectl --kubeconfig="$KUBECONFIG_OUT" config set-cluster k3d-kip \
  --server="$SERVER"
kubectl --kubeconfig="$KUBECONFIG_OUT" config set clusters.k3d-kip.certificate-authority-data "$CA_DATA"
kubectl --kubeconfig="$KUBECONFIG_OUT" config set-credentials "$SA" --token="$TOKEN"
kubectl --kubeconfig="$KUBECONFIG_OUT" config set-context "$SA" \
  --cluster=k3d-kip --user="$SA" --namespace="$NS"
kubectl --kubeconfig="$KUBECONFIG_OUT" config use-context "$SA"
```

Повторить для `student01`, `student02`, `student03` (меняя `NS`/`SA`).

Итог — 4 независимых файла:
```
module-02-security/kubeconfig/mentor.kubeconfig
module-02-security/kubeconfig/student01.kubeconfig
module-02-security/kubeconfig/student02.kubeconfig
module-02-security/kubeconfig/student03.kubeconfig
```

Эти файлы **не коммитим** в git (в них токены) — только сам механизм/скрипт их
генерации коммитим, а сами файлы передаём людям напрямую или кладём в
`.gitignore`.

---

## Шаг 5. Проверка RBAC (до/после применения)

Самый быстрый способ проверить права без переключения kubeconfig —
`kubectl auth can-i ... --as=system:serviceaccount:<ns>:<sa>`:

```bash
# mentor должен RW в student01/02/03, но НЕ в default и НЕ видеть nodes
kubectl --context k3d-kip auth can-i create pods -n student01 --as=system:serviceaccount:mentor:mentor   # yes
kubectl --context k3d-kip auth can-i get pods -n default --as=system:serviceaccount:mentor:mentor         # no
kubectl --context k3d-kip auth can-i list nodes --as=system:serviceaccount:mentor:mentor                  # no
kubectl --context k3d-kip auth can-i '*' '*' --as=system:serviceaccount:mentor:mentor                     # no (not cluster-admin)

# student01: RW только в своём ns
kubectl --context k3d-kip auth can-i create pods -n student01 --as=system:serviceaccount:student01:student01  # yes
kubectl --context k3d-kip auth can-i get pods -n student02 --as=system:serviceaccount:student01:student01     # no

# student02: RW в своём, RO в student01 и default
kubectl --context k3d-kip auth can-i create pods -n student02 --as=system:serviceaccount:student02:student02  # yes
kubectl --context k3d-kip auth can-i get pods -n student01 --as=system:serviceaccount:student02:student02     # yes
kubectl --context k3d-kip auth can-i create pods -n student01 --as=system:serviceaccount:student02:student02  # no
kubectl --context k3d-kip auth can-i get pods -n default --as=system:serviceaccount:student02:student02       # yes
kubectl --context k3d-kip auth can-i create pods -n default --as=system:serviceaccount:student02:student02    # no

# student03: RW только в своём ns
kubectl --context k3d-kip auth can-i create pods -n student03 --as=system:serviceaccount:student03:student03  # yes
kubectl --context k3d-kip auth can-i get pods -n student01 --as=system:serviceaccount:student03:student03     # no
```

Можно также реально переключиться на выданный kubeconfig и попробовать `kubectl --kubeconfig=... get pods`.

---

## Шаг 6. Установка Kyverno

Kyverno — через official Helm chart (установка самого Kyverno — это установка
инструмента в кластер, а не "наши" манифесты ДЗ, поэтому Helm тут нормален и
не противоречит решению писать policy YAML-ом):

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno-system --create-namespace
kubectl --context k3d-kip wait --for=condition=Ready pods --all -n kyverno-system --timeout=120s
```

---

## Шаг 7. Kyverno Policy #1 — readonly root filesystem (audit)

Задача: провалидировать, что `securityContext.readOnlyRootFilesystem: true`
стоит у всех контейнеров, но в режиме **audit** — то есть ничего не блокируется,
нарушения только логируются/видны в `PolicyReport`.

`validationFailureAction: Audit` именно это и делает (в отличие от `Enforce`,
который бы реально блокировал создание подов).

Файл `03-kyverno-readonly-rootfs-audit.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-readonly-rootfs
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: validate-readonly-rootfs
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Container must set securityContext.readOnlyRootFilesystem=true"
        pattern:
          spec:
            containers:
              - securityContext:
                  readOnlyRootFilesystem: true
```

`match.resources.kinds: [Pod]` — Kyverno **автоматически** генерирует (autogen)
аналогичные правила для Deployment/StatefulSet/DaemonSet/Job/CronJob, так что
проверка сработает и если студент создаёт под напрямую, и если через Deployment
(как это бывает в реальности почти всегда).

Применить:
```bash
kubectl --context k3d-kip apply -f module-02-security/03-kyverno-readonly-rootfs-audit.yaml
```

Проверка — создать тестовый под без `readOnlyRootFilesystem` и посмотреть отчёт:
```bash
kubectl --context k3d-kip run test-rootfs --image=nginx -n student01
kubectl --context k3d-kip get policyreport -n student01
kubectl --context k3d-kip get policyreport -n student01 -o yaml | grep -A5 require-readonly-rootfs
```

---

## Шаг 8. Kyverno Policy #2 — label "person"

Задача: домутировать (`mutate`) под лейблом `person`:
- в `student01`/`student02`/`student03` → `person: student`
- в `mentor` → `person: mentor`
- во всех остальных namespace (`default`, `kube-system` и т.п.) → лейбла нет вообще

Так как "остальные namespace не должны иметь лейбл вообще" — это значит делать
**три отдельных правила с точным списком namespace** (а не одно правило + exclude),
без правила "для всех остальных" — тогда по умолчанию лейбл просто не добавляется
там, где правило не сработало.

Файл `04-kyverno-person-label.yaml`:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-person-label
spec:
  rules:
    - name: label-student-namespaces
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - student01
                - student02
                - student03
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              person: student
    - name: label-mentor-namespace
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - mentor
      mutate:
        patchStrategicMerge:
          metadata:
            labels:
              person: mentor
```

Применить:
```bash
kubectl --context k3d-kip apply -f module-02-security/04-kyverno-person-label.yaml
```

Проверка:
```bash
kubectl --context k3d-kip run t1 --image=nginx -n student01 --dry-run=server -o jsonpath='{.metadata.labels}'
# ожидаем: {"person":"student", ...}

kubectl --context k3d-kip run t2 --image=nginx -n mentor --dry-run=server -o jsonpath='{.metadata.labels}'
# ожидаем: {"person":"mentor", ...}

kubectl --context k3d-kip run t3 --image=nginx -n default --dry-run=server -o jsonpath='{.metadata.labels}'
# ожидаем: лейбла person нет
```

---

## Итоговый порядок применения (когда дадите добро)

```bash
kubectl --context k3d-kip apply -f module-02-security/00-namespaces.yaml
kubectl --context k3d-kip apply -f module-02-security/01-service-accounts.yaml
kubectl --context k3d-kip apply -f module-02-security/02-rbac.yaml
# генерация kubeconfig — шаг 4, вручную/скриптом
helm install kyverno kyverno/kyverno -n kyverno-system --create-namespace
kubectl --context k3d-kip apply -f module-02-security/03-kyverno-readonly-rootfs-audit.yaml
kubectl --context k3d-kip apply -f module-02-security/04-kyverno-person-label.yaml
```

## Оформление как PR

Коммитим `module-02-security/*.yaml` (кроме `kubeconfig/`), пишем в `README.md`
внутри папки команды проверки (шаги 5, 7, 8), открываем PR из ветки `module_02`
(или текущей `module_01`, если по курсу это продолжение) в `main`, прикладываем
ссылку на платформу курса.

---

## Замечания / компромиссы, которые ментор может попросить объяснить

1. **ServiceAccount вместо TLS-сертификатов** — на реальном проде людям обычно
   выдают доступ через облачный IAM/OIDC. Локально такого провайдера нет;
   ServiceAccount-токен — штатный, поддерживаемый k3s механизм идентификации,
   проще в выдаче и отзыве (`kubectl delete sa ...` — токен сразу недействителен),
   это и обосновывает выбор.
2. **ClusterRole + RoleBinding, а не Role в каждом namespace** — чтобы не
   дублировать одинаковый список прав 3-4 раза; `ClusterRole` тут не даёт прав
   сама по себе, права появляются только там, где есть `RoleBinding`.
3. **`validationFailureAction: Audit`** — специально выбран, чтобы НЕ блокировать
   создание подов без readonly rootfs (так и просит задание — "в режимі аудиту").
   Enforce стоит обсуждать отдельно, как следующий шаг зрелости policy.
