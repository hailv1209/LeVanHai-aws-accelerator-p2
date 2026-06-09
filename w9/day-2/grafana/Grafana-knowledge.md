# Grafana — Lý thuyết & Cú pháp

---

## 1. Grafana là gì?

**Grafana** là open-source analytics & interactive visualization platform, kết nối với nhiều data sources để tạo dashboards.

```
┌──────────────────────────────────────────────────────────────┐
│                       GRAFANA STACK                          │
│                                                              │
│   ┌─────────────┐  ┌──────────────┐  ┌───────────────┐    │
│   │ Prometheus  │  │    Loki      │  │    Tempo     │    │
│   │  (Metrics)  │  │   (Logs)     │  │   (Traces)   │    │
│   └──────┬──────┘  └──────┬───────┘  └───────┬───────┘   │
│          │                 │                   │             │
│          ▼                 ▼                   ▼             │
│   ┌─────────────────────────────────────────────────────┐  │
│   │                  GRAFANA UNIFIED UI                   │  │
│   │  Dashboards | Explore Logs | Trace Viewer | Alerts   │  │
│   └─────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

**Tính năng chính:**

- Multi-data source: Prometheus, Loki, Tempo, Elasticsearch, InfluxDB, MySQL...
- Interactive dashboards: zoom, pan, variable interpolation
- Alerting: alert rules → notification channels (Slack, PagerDuty, email...)
- Variables & Templating: dynamic dashboards
- Explore mode: truy vấn ad-hoc logs, traces, metrics
- Annotations: ghi chú event trên dashboard
- Permission/RBAC: kiểm soát truy cập

---

## 2. Data Source Configuration

### 2.1 Prometheus Data Source

```json
{
  "name": "Prometheus",
  "type": "prometheus",
  "access": "server",
  "url": "http://prometheus.monitoring:9090",
  "jsonData": {
    "httpMethod": "POST",
    "timeInterval": "15s",
    "queryTimeout": "60s",
    "manageAlerts": true,
    "prometheusType": "default",
    "prometheusVersion": "2.45.0"
  },
  "isDefault": true
}
```

### 2.2 Loki Data Source

```json
{
  "name": "Loki",
  "type": "loki",
  "access": "server",
  "url": "http://loki.monitoring:3100",
  "jsonData": {
    "maxLines": 500,
    "derivedFields": [
      {
        "name": "trace_id",
        "matcherRegex": "trace_id=(\\w+)",
        "url": "http://tempo.monitoring:3100/trace/${__value}",
        "datasourceUid": "tempo"
      }
    ]
  }
}
```

### 2.3 Tempo Data Source (Traces)

```json
{
  "name": "Tempo",
  "type": "tempo",
  "url": "http://tempo.monitoring:3100",
  "access": "server",
  "jsonData": {
    "serviceMap": {
      "datasourceUid": "prometheus"
    },
    "nodeGraph": {
      "enabled": true
    },
    "search": {
      "hide": false
    }
  }
}
```

---

## 3. Dashboard & Panel — Cú pháp JSON

### 3.1 Dashboard JSON Model

```json
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": {
          "type": "grafana",
          "uid": "-- Grafana --"
        },
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "liveNow": false,
  "panels": [],
  "refresh": "30s",
  "schemaVersion": 38,
  "style": "dark",
  "tags": ["kubernetes", "slo"],
  "templating": {
    "list": [
      {
        "name": "datasource",
        "type": "datasource",
        "query": "prometheus",
        "refresh": 1,
        "current": {}
      },
      {
        "name": "service",
        "type": "query",
        "datasource": {
          "type": "prometheus",
          "uid": "${datasource}"
        },
        "query": {
          "query": "label_values(http_requests_total, service)",
          "refId": "StandardVariableQuery"
        },
        "multi": true,
        "includeAll": true
      },
      {
        "name": "slo_threshold",
        "type": "constant",
        "query": "99.9",
        "current": {
          "selected": false,
          "text": "99.9",
          "value": "99.9"
        }
      }
    ]
  },
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "browser",
  "title": "SLO Dashboard",
  "uid": "slo-overview",
  "version": 1,
  "weekStart": ""
}
```

### 3.2 Panel Types — Cú pháp

**Stat Panel:**

```json
{
  "title": "Availability (SLO 99.9%)",
  "type": "stat",
  "gridPos": {"h": 6, "w": 6, "x": 0, "y": 0},
  "datasource": {"type": "prometheus", "uid": "${datasource}"},
  "fieldConfig": {
    "defaults": {
      "unit": "percentunit",
      "min": 0.99,
      "max": 1.0,
      "thresholds": {
        "mode": "absolute",
        "steps": [
          {"color": "red", "value": null},
          {"color": "yellow", "value": 0.997},
          {"color": "green", "value": 0.999}
        ]
      },
      "mappings": [],
      "decimals": 4
    }
  },
  "options": {
    "colorMode": "value",
    "graphMode": "none",
    "justifyMode": "auto",
    "orientation": "auto",
    "reduceOptions": {
      "calcs": ["lastNotNull"],
      "fields": "",
      "values": false
    },
    "textMode": "auto"
  },
  "targets": [
    {
      "expr": "sum(rate(http_requests_total{status=~\"2..\"}[5m])) / sum(rate(http_requests_total[5m]))",
      "refId": "A"
    }
  ]
}
```

**Time Series Panel:**

```json
{
  "title": "p99 Latency",
  "type": "timeseries",
  "gridPos": {"h": 8, "w": 12, "x": 6, "y": 0},
  "datasource": {"type": "prometheus", "uid": "${datasource}"},
  "fieldConfig": {
    "defaults": {
      "unit": "ms",
      "custom": {
        "lineWidth": 2,
        "fillOpacity": 10,
        "gradientMode": "none",
        "axisCenteredZero": false,
        "showPoints": "never",
        "spanNulls": true
      },
      "thresholds": {
        "mode": "absolute",
        "steps": [
          {"color": "green", "value": null},
          {"color": "yellow", "value": 300},
          {"color": "red", "value": 500}
        ]
      }
    }
  },
  "options": {
    "legend": {
      "displayMode": "table",
      "placement": "bottom",
      "calcs": ["mean", "max", "last"]
    },
    "tooltip": {
      "mode": "multi",
      "sort": "desc"
    }
  },
  "targets": [
    {
      "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)) * 1000",
      "legendFormat": "p99 - {{service}}",
      "refId": "A"
    }
  ]
}
```

**Gauge Panel (Error Budget):**

```json
{
  "title": "Error Budget Remaining",
  "type": "gauge",
  "gridPos": {"h": 6, "w": 6, "x": 12, "y": 6},
  "datasource": {"type": "prometheus", "uid": "${datasource}"},
  "fieldConfig": {
    "defaults": {
      "unit": "percentunit",
      "min": 0,
      "max": 1,
      "thresholds": {
        "mode": "absolute",
        "steps": [
          {"color": "red", "value": null},
          {"color": "yellow", "value": 0.1},
          {"color": "green", "value": 0.5}
        ]
      }
    }
  },
  "options": {
    "orientation": "auto",
    "reduceOptions": {
      "calcs": ["lastNotNull"],
      "fields": "",
      "values": false
    },
    "showThresholdLabels": false,
    "showThresholdMarkers": true
  },
  "targets": [
    {
      "expr": "1 - ((1 - (sum(rate(http_requests_total{status=~\"2..\"}[30d])) / sum(rate(http_requests_total[30d])))) / (1 - 0.999))",
      "refId": "A"
    }
  ]
}
```

**Bar Gauge Panel:**

```json
{
  "title": "Error Rate by Service",
  "type": "bargauge",
  "gridPos": {"h": 6, "w": 12, "x": 0, "y": 12},
  "datasource": {"type": "prometheus", "uid": "${datasource}"},
  "fieldConfig": {
    "defaults": {
      "unit": "percentunit",
      "thresholds": {
        "mode": "absolute",
        "steps": [
          {"color": "green", "value": null},
          {"color": "yellow", "value": 0.001},
          {"color": "red", "value": 0.005}
        ]
      }
    }
  },
  "options": {
    "displayMode": "gradient",
    "orientation": "horizontal",
    "showUnfilled": true
  },
  "targets": [
    {
      "expr": "sum(rate(http_requests_total{status=~\"5..\"}[5m])) by (service) / sum(rate(http_requests_total[5m])) by (service)",
      "legendFormat": "{{service}}",
      "refId": "A"
    }
  ]
}
```

---

## 4. Grafana Alerting

### 4.1 Alert Rule — JSON definition

```json
{
  "title": "SLO Availability Alert",
  "uid": "slo-availability-alert",
  "namespaceUid": "slo-alerts",
  "condition": "C",
  "data": [
    {
      "refId": "A",
      "queryType": "",
      "relativeTimeRange": {
        "from": 300,
        "to": 0
      },
      "datasourceUid": "prometheus",
      "model": {
        "expr": "sum(rate(http_requests_total{status=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m]))",
        "intervalMs": 1000,
        "maxDataPoints": 43200,
        "refId": "A"
      }
    },
    {
      "refId": "B",
      "queryType": "",
      "relativeTimeRange": {
        "from": 300,
        "to": 0
      },
      "datasourceUid": "__expr__",
      "model": {
        "conditions": [
          {
            "evaluator": {
              "params": [0],
              "type": "gt"
            },
            "operator": {
              "type": "and"
            },
            "query": {
              "params": ["B"]
            },
            "reducer": {
              "params": [],
              "type": "last"
            },
            "type": "query"
          }
        ],
        "datasource": {
          "type": "__expr__",
          "uid": "__expr__"
        },
        "expression": "A",
        "reducer": "last",
        "refId": "B",
        "type": "reduce"
      }
    },
    {
      "refId": "C",
      "queryType": "",
      "relativeTimeRange": {
        "from": 300,
        "to": 0
      },
      "datasourceUid": "__expr__",
      "model": {
        "conditions": [
          {
            "evaluator": {
              "params": [0.001],
              "type": "gt"
            },
            "operator": {
              "type": "and"
            },
            "query": {
              "params": ["C"]
            },
            "reducer": {
              "params": [],
              "type": "last"
            },
            "type": "query"
          }
        ],
        "datasource": {
          "type": "__expr__",
          "uid": "__expr__"
        },
        "expression": "B",
        "refId": "C",
        "type": "threshold"
      }
    }
  ],
  "noDataState": "NoData",
  "execErrState": "Error",
  "for": "5m",
  "annotations": {
    "summary": "SLO Availability breached! Current: {{ $values.B.Value | printf \"%.4f\" }}",
    "runbook_url": "https://wiki.example.com/runbooks/slo-availability"
  },
  "labels": {
    "severity": "critical",
    "slo": "availability",
    "team": "platform"
  }
}
```

### 4.2 Notification Policy / Contact Point

```yaml
# Grafana Alerting Config (via Grafana provisioning)

# contact-points.yaml
apiVersion: 1
kind: ContactPoints
metadata:
  name: platform-alerts
spec:
  - name: slack-platform
    receivers:
      - uid: slack-critical
        type: slack
        settings:
          url: "{{ .SlackWebhookURL }}"
          recipient: "#alerts-platform"
          title: "{{ .CommonLabels.alertname }}"
          text: |
            {{ range .Alerts }}
            *Alert:* {{ .Labels.alertname }}
            *Severity:* {{ .Labels.severity }}
            *Summary:* {{ .Annotations.summary }}
            *Service:* {{ .Labels.service }}
            *Value:* {{ .Values.B.Value | printf "%.4f" }}
            {{ end }}

  - name: pagerduty-critical
    receivers:
      - uid: pagerduty
        type: pagerduty
        settings:
          integrationKey: "{{ .PagerDutyIntegrationKey }}"
          severity: critical

  - name: email-oncall
    receivers:
      - uid: email
        type: email
        settings:
          addresses: oncall@example.com
          singleEmail: true
```

```yaml
# notification-policies.yaml
apiVersion: 1
kind: NotificationPolicy
metadata:
  name: slo-alerting
spec:
  contactPoint: slack-platform
  groupBy:
    - alertname
    - service
  groupWait: 30s
  groupInterval: 5m
  repeatInterval: 4h
  routes:
    - receiver: pagerduty-critical
      matchers:
        - severity = critical
        - slo = availability
      continue: true
    - receiver: slack-platform
      matchers:
        - severity = warning
```

---

## 5. Grafana Provisioning — Dashboard-as-Code

```yaml
# dashboard-provisioning.yaml
apiVersion: 1
providers:
  - name: 'SLO Dashboards'
    orgId: 1
    folder: 'SLO'
    folderUid: slo-dashboards
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards/slo

---
# datasource-provisioning.yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: server
    url: http://prometheus.monitoring:9090
    isDefault: true
    jsonData:
      httpMethod: POST
      timeInterval: 15s

  - name: Loki
    type: loki
    access: server
    url: http://loki.monitoring:3100
```

```bash
# Mount dashboard files
kubectl create configmap grafana-slo-dashboards \
  --from-file=slo-overview.json=./dashboards/slo-overview.json \
  --from-file=slo-latency.json=./dashboards/slo-latency.json \
  -n monitoring

kubectl label configmap grafana-slo-dashboards \
  grafana_dashboard="1" -n monitoring
```

---

## Tổng kết cú pháp

| Thành phần | Cú pháp / Mục đích |
|---|---|
| **Stat Panel** | `lastNotNull` calc, `percentunit` unit, threshold steps |
| **Time Series** | `timeseries` type, `ms` unit, `histogram_quantile` |
| **Gauge Panel** | `gauge` type, min/max bounds, threshold markers |
| **Log Panel** | Loki datasource, `{{message}}` template |
| **Trace Panel** | Tempo datasource, `servicegraph` visualization |
| **Alert Rule** | `condition`, `for: 5m`, `annotations`, `labels` |
| **Contact Point** | Slack/PagerDuty/email integration |
| **Provisioning** | ConfigMap + label `grafana_dashboard=1` |
