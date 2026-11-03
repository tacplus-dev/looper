#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# looper-trace (looper#51) against a fixture service, in Go and in Rust: a
# handler with one causal downstream call (it carries the inbound trace_id) and
# one unrelated call (marked `trace: unrelated: <why>`), a background loop
# that is no handler, and a test asserting the trace_id on the causal call.
# The check passes when the code is right; it flags a dropped trace_id on the
# causal call, never the unrelated one, a marker that gives no reason, and a
# handler with no propagation test; generated code is not read. A seam taking a
# row by value and its trace_id as a parameter carries the parameter (#66).
# Run: tests/looper-trace.test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL $NAME: $*" >&2; exit 1; }
pass() { echo "ok $NAME"; }
has() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }
lacks() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected \"$2\" in: $1"; }
trace() { OUT="$("$ROOT/looper-trace" "$@" 2>&1)"; }
passes() { trace check "$S" || fail "expected the check to pass: $OUT"; }
flagged() { if trace check "$S"; then fail "expected the check to fail: $OUT"; fi; }

# The Go fixture: internal/handler.go and its test, as USER.md's pattern has them.
go_service() { # name
  NAME="go-$1"; S="$TMP/$NAME"; mkdir -p "$S/internal" "$S/model/order"
  printf 'language: go\noutput-dir: model\n' > "$S/tacplus.yaml"
  cat > "$S/internal/handler.go" <<'GO'
package internal

import (
	"context"

	inventorypb "example.test/shop/model/inventory"
	metricspb "example.test/shop/model/metrics"
	orderpb "example.test/shop/model/order"
	"example.test/shop/model/s2sm"
)

type orderImpl struct{ sm *s2sm.ServiceManager }

// PlaceOrder reserves the order's item, which the request causes, and counts
// it for the metrics batch, which it does not.
func (s *orderImpl) PlaceOrder(ctx context.Context, req *orderpb.PlaceOrderRequest) (*orderpb.PlaceOrderResponse, error) {
	reserve := &inventorypb.ReserveRequest{
		Sku:     req.Sku,
		TraceId: req.TraceId, // propagate
	}
	if _, err := s.sm.Grpc().Clients().Inventory().InventoryApiClient().Reserve(ctx, reserve); err != nil {
		return nil, err
	}
	// trace: unrelated: the metrics batch counts orders across requests; no one request causes it
	s.sm.Grpc().Clients().Metrics().MetricsApiClient().Count(ctx, &metricspb.CountRequest{Name: "orders"})
	return &orderpb.PlaceOrderResponse{}, nil
}

// flushLoop is background work: no request causes it, and it is no handler.
func (s *orderImpl) flushLoop(ctx context.Context) {
	api := s.sm.Grpc().Clients().Metrics().MetricsApiClient()
	api.Flush(ctx, &metricspb.FlushRequest{})
}
GO
  cat > "$S/internal/handler_test.go" <<'GO'
package internal

import (
	"context"
	"testing"

	orderpb "example.test/shop/model/order"
)

func TestPlaceOrderRejectsAnEmptySku(t *testing.T) {
	s, _ := newTestImpl(t)
	if _, err := s.PlaceOrder(context.Background(), &orderpb.PlaceOrderRequest{}); err == nil {
		t.Fatal("an empty sku was accepted")
	}
}

func TestPlaceOrderPropagatesTrace(t *testing.T) {
	s, inventory := newTestImpl(t)
	req := &orderpb.PlaceOrderRequest{Sku: "a", TraceId: "8f3c2a9d41b07e65c1d4a2b39e0f7d18"}
	if _, err := s.PlaceOrder(context.Background(), req); err != nil {
		t.Fatal(err)
	}
	if got := inventory.Reserved[0].GetTraceId(); got != req.TraceId {
		t.Fatalf("Reserve got trace_id %q, want the inbound %q", got, req.TraceId)
	}
}
GO
  # Generated code is never read: a generated client that drops the trace_id is not the handler's.
  cat > "$S/model/order/client.go" <<'GO'
package order

func (c *InventoryApiClient) Reserve(ctx context.Context, in *ReserveRequest) (*ReserveResponse, error) {
	return c.sm.Grpc().Clients().Inventory().InventoryApiClient().Reserve(ctx, &ReserveRequest{Sku: in.Sku})
}
GO
}

# The Rust fixture: src/handler.rs, its test in the file's tests module.
rust_service() { # name
  NAME="rust-$1"; S="$TMP/$NAME"; mkdir -p "$S/src"
  cat > "$S/src/handler.rs" <<'RS'
use crate::model::{CountRequest, PlaceOrderRequest, PlaceOrderResponse, ProtoError, ReserveRequest};

impl OrderImpl {
    /// Reserves the order's item, which the request causes, and counts it for
    /// the metrics batch, which it does not.
    pub async fn place_order(&self, req: PlaceOrderRequest) -> Result<PlaceOrderResponse, ProtoError> {
        let reserve = ReserveRequest {
            sku: req.sku.clone(),
            trace_id: req.trace_id.clone(), // propagate
            ..Default::default()
        };
        self.sm.s2s().inventory().inventory_api_client().reserve(reserve).await?;
        // trace: unrelated: the metrics batch counts orders across requests; no one request causes it
        self.sm
            .s2s()
            .metrics()
            .metrics_api_client()
            .count(CountRequest { name: "orders".into(), ..Default::default() })
            .await?;
        Ok(PlaceOrderResponse::default())
    }

    /// Background work: no request causes it, and it is no handler.
    async fn flush_loop(&self) {
        let api = self.sm.s2s().metrics().metrics_api_client();
        let _ = api.flush(FlushRequest::default()).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn place_order_propagates_trace() {
        let (svc, inventory) = test_impl();
        let req = PlaceOrderRequest { sku: "a".into(), trace_id: "8f3c2a9d41b07e65c1d4a2b39e0f7d18".into(), ..Default::default() };
        svc.place_order(req.clone()).await.unwrap();
        assert_eq!(inventory.reserved()[0].trace_id, req.trace_id);
    }
}
RS
}
edit() { # file perl-expression
  perl -0pi -e "$2" "$S/$1"
}

for lang in go rust; do
  "${lang}_service" right
  passes
  if [[ "$lang" == go ]]; then
    has "$OUT" "handler internal/handler.go:16 PlaceOrder (inbound: req)"
    has "$OUT" "causal internal/handler.go:21 Reserve: carries the inbound trace_id"
    has "$OUT" "unrelated internal/handler.go:25 Count: the metrics batch counts orders across requests"
    has "$OUT" "tested by internal/handler_test.go:17 TestPlaceOrderPropagatesTrace"
    lacks "$OUT" "TestPlaceOrderRejectsAnEmptySku"; lacks "$OUT" "flushLoop"; lacks "$OUT" "model/order"
  else
    has "$OUT" "handler src/handler.rs:6 place_order (inbound: req)"
    has "$OUT" "causal src/handler.rs:12 reserve: carries the inbound trace_id"
    has "$OUT" "unrelated src/handler.rs:18 count: the metrics batch counts orders across requests"
    has "$OUT" "tested by src/handler.rs:35 place_order_propagates_trace"
    lacks "$OUT" "flush_loop"
  fi
  has "$OUT" "verdict: pass (1 handler, 0 findings)"
  pass

  # The causal call without the inbound trace_id: flagged; the unrelated one still is not.
  "${lang}_service" dropped
  if [[ "$lang" == go ]]; then edit internal/handler.go 's/\t\tTraceId: req.TraceId, \/\/ propagate\n//'
  else edit src/handler.rs 's/ {12}trace_id: req.trace_id.clone\(\), \/\/ propagate\n//'; fi
  flagged
  if [[ "$lang" == go ]]; then
    has "$OUT" "FINDING dropped-trace internal/handler.go:20: PlaceOrder's call Reserve is caused by the request but does not carry its trace_id (req)"
    lacks "$OUT" "call Count"
  else
    has "$OUT" "FINDING dropped-trace src/handler.rs:11: place_order's call reserve is caused by the request but does not carry its trace_id (req)"
    lacks "$OUT" "call count"
  fi
  has "$OUT" "verdict: fail (1 finding)"
  pass

  # A marker must say why: without a reason, the unrelated call counts as causal.
  "${lang}_service" marker-without-reason
  if [[ "$lang" == go ]]; then edit internal/handler.go 's/trace: unrelated: [^\n]*/trace: unrelated/'
  else edit src/handler.rs 's/trace: unrelated: [^\n]*/trace: unrelated/'; fi
  flagged
  if [[ "$lang" == go ]]; then has "$OUT" "FINDING dropped-trace internal/handler.go:25: PlaceOrder's call Count"
  else has "$OUT" "FINDING dropped-trace src/handler.rs:18: place_order's call count"; fi
  has "$OUT" "its \`trace: unrelated\` marker gives no reason"
  pass

  # No test asserts the trace_id on the handler's calls (a test that calls it without one does not count).
  "${lang}_service" no-test
  if [[ "$lang" == go ]]; then
    edit internal/handler_test.go 's/\nfunc TestPlaceOrderPropagatesTrace.*//s'
  else
    edit src/handler.rs 's/assert_eq!\(inventory.reserved\(\)\[0\].trace_id, req.trace_id\);/assert_eq!(inventory.reserved().len(), 1);/; s/, trace_id: "8f3c2a9d41b07e65c1d4a2b39e0f7d18".into\(\)//'
  fi
  flagged
  if [[ "$lang" == go ]]; then
    has "$OUT" "FINDING untested internal/handler.go:16: PlaceOrder makes causal downstream calls (Reserve) but no test asserts that its trace_id arrives on them"
  else
    has "$OUT" "FINDING untested src/handler.rs:6: place_order makes causal downstream calls (reserve) but no test asserts that its trace_id arrives on them"
  fi
  lacks "$OUT" "dropped-trace"
  has "$OUT" "verdict: fail (1 finding)"
  pass
done

# The trace_id through a local variable and a client kept in a variable (Go),
# and a tonic request's inner message (Rust): still propagated.
go_service aliases
edit internal/handler.go 's/\treserve := /\ttid := req.GetTraceId()\n\tinv := s.sm.Grpc().Clients().Inventory().InventoryApiClient()\n\treserve := /; s/TraceId: req.TraceId, \/\/ propagate/TraceId: tid,/; s/s.sm.Grpc\(\).Clients\(\).Inventory\(\).InventoryApiClient\(\).Reserve/inv.Reserve/'
passes
has "$OUT" "causal internal/handler.go:23 Reserve: carries the inbound trace_id"
pass
go_service aliases-dropped
edit internal/handler.go 's/\treserve := /\tinv := s.sm.Grpc().Clients().Inventory().InventoryApiClient()\n\treserve := /; s/\t\tTraceId: req.TraceId, \/\/ propagate\n//; s/s.sm.Grpc\(\).Clients\(\).Inventory\(\).InventoryApiClient\(\).Reserve/inv.Reserve/'
flagged
has "$OUT" "FINDING dropped-trace internal/handler.go:21: PlaceOrder's call Reserve"
pass
rust_service tonic
edit src/handler.rs 's/place_order\(&self, req: PlaceOrderRequest\)/place_order(&self, request: tonic::Request<PlaceOrderRequest>)/; s/(-> Result<PlaceOrderResponse, ProtoError> \{\n)/$1        let req = request.into_inner();\n/'
passes
has "$OUT" "handler src/handler.rs:6 place_order (inbound: request, req)"
pass
# A proxy forwards the inbound request itself, its trace_id with it; a function
# taking only references (a REST route, the server's state) is no handler.
rust_service proxy
cat >> "$S/src/handler.rs" <<'RS'

#[tonic::async_trait]
impl Mint for MintImpl {
    async fn mint_token(&self, request: tonic::Request<TokenMintRequest>) -> Result<tonic::Response<TokenMintResponse>, tonic::Status> {
        self.sm.s2s().kernel().minter_client().mint_token(request).await
    }
}

async fn route_mint(route: &RouteInfo, state: &RestState) -> Response {
    state.sm.s2s().kernel().minter_client().mint_token(build(route)).await
}
RS
flagged
has "$OUT" "causal src/handler.rs:46 mint_token: carries the inbound trace_id"
lacks "$OUT" "route_mint"; lacks "$OUT" "dropped-trace"
has "$OUT" "FINDING untested src/handler.rs:45: mint_token makes causal downstream calls (mint_token)"
pass
# The trace_id handed to a request builder, a client reached through an
# accessor method; another library's client (Kubernetes') is no tacplus call.
rust_service builder-accessor
cat >> "$S/src/handler.rs" <<'RS'

impl Callback {
    fn mint(&self) -> &MintGrpcClient {
        self.sm.s2s().kernel().mint_client()
    }

    async fn callback(&self, req: CallbackRequest) -> Result<CallbackResponse, tonic::Status> {
        let tokens = self.mint().mint_user_token(mint_request(&req.subject, &req.trace_id)).await?;
        let _ = self.mint().revoke(RevokeRequest { subject: req.subject.clone(), ..Default::default() }).await;
        Ok(CallbackResponse::from(tokens))
    }
}
RS
flagged
has "$OUT" "causal src/handler.rs:49 mint_user_token: carries the inbound trace_id"
has "$OUT" "FINDING dropped-trace src/handler.rs:50: callback's call revoke"
pass
# A seam handed the trace_id as its own parameter (mailbox#10): the store takes
# the row by value, which is no request (its own trace_id would be the wrong
# one), and sets the request's trace_id from the parameter; the handler's test,
# through the function that calls the seam, covers it.
rust_seam() { # name
  rust_service "$1"
  cat > "$S/src/store.rs" <<'RS'
#[async_trait::async_trait]
pub trait EntryStore: Send + Sync {
    async fn insert_if_absent(&self, tenant: &str, entry: MailboxEntry, trace_id: &str) -> Result<i64, tonic::Status>;
}

impl RecordStore {
    fn client(&self) -> &RecordMapGrpcClient {
        self.0.s2s().stratum().record_map_client()
    }
}

#[async_trait::async_trait]
impl EntryStore for RecordStore {
    async fn insert_if_absent(
        &self,
        tenant: &str,
        entry: MailboxEntry,
        trace_id: &str,
    ) -> Result<i64, tonic::Status> {
        Ok(self
            .client()
            .insert_if_absent_mailbox_entry(InsertIfAbsentMailboxEntryRequest {
                item: Some(entry),
                target_tenant: tenant.to_string(),
                trace_id: trace_id.to_string(),
                ..Default::default()
            })
            .await?
            .into_inner()
            .revision)
    }
}

impl MailboxService {
    pub async fn on_message(&self, msg: Delivery) -> Result<(), tonic::Status> {
        let trace_id = msg.trace_id;
        let entry = MailboxEntry { delivery_id: msg.id, ..Default::default() };
        self.rows.insert_if_absent(&msg.tenant, entry, &trace_id).await?;
        Ok(())
    }
}

impl Wrapper {
    async fn on_stream(&self, msg: Delivery) -> Result<(), tonic::Status> {
        self.svc.on_message(msg).await
    }
}
RS
  cat > "$S/src/store_tests.rs" <<'RS'
#[tokio::test]
async fn a_delivery_carries_its_trace_id_to_the_insert() {
    let h = Harness::start().await;
    let mut msg = delivery("m1");
    msg.trace_id = "t-1".to_string();
    h.wrapper.on_stream(msg).await.expect("consume");
    assert_eq!(h.stratum.traces(), vec![("insert_if_absent", "t-1".to_string())]);
}
RS
}
rust_seam seam
passes
has "$OUT" "seam src/store.rs:14 insert_if_absent (trace: trace_id)"
has "$OUT" "causal src/store.rs:22 insert_if_absent_mailbox_entry: carries the inbound trace_id"
has "$OUT" "tested by src/store_tests.rs:2 a_delivery_carries_its_trace_id_to_the_insert (through on_stream)"
lacks "$OUT" "inbound: entry"
has "$OUT" "verdict: pass (2 handlers, 0 findings)"
pass
# The seam that ignores its trace_id, or sets the row's own: dropped.
rust_seam seam-dropped
edit src/store.rs 's/trace_id: trace_id.to_string\(\),/trace_id: entry.trace_id.clone(),/'
flagged
has "$OUT" "FINDING dropped-trace src/store.rs:22: insert_if_absent's call insert_if_absent_mailbox_entry is caused by the request but does not carry its trace_id (trace_id)"
pass
# No test that reaches the seam names the trace_id: untested.
rust_seam seam-untested
rm "$S/src/store_tests.rs"
flagged
has "$OUT" "FINDING untested src/store.rs:14: insert_if_absent makes causal downstream calls (insert_if_absent_mailbox_entry) but no test asserts that its trace_id arrives on them"
lacks "$OUT" "dropped-trace"
pass
# Go: a row by pointer and a traceID string.
go_service seam
cat >> "$S/internal/handler.go" <<'GO'

func (s *store) Insert(ctx context.Context, row *orderpb.Entry, traceID string) error {
	_, err := s.sm.Grpc().Clients().Stratum().RecordMapClient().InsertIfAbsent(ctx, &stratumpb.InsertRequest{Item: row, TraceId: traceID})
	return err
}
GO
cat >> "$S/internal/handler_test.go" <<'GO'

func TestInsertCarriesTrace(t *testing.T) {
	s, rec := newTestStore(t)
	if err := s.Insert(context.Background(), &orderpb.Entry{}, "t-1"); err != nil || rec.TraceId != "t-1" {
		t.Fatal(err)
	}
}
GO
passes
has "$OUT" "seam internal/handler.go:35 Insert (trace: traceID)"
has "$OUT" "causal internal/handler.go:36 InsertIfAbsent: carries the inbound trace_id"
has "$OUT" "tested by internal/handler_test.go:28 TestInsertCarriesTrace"
pass
go_service other-clients
cat >> "$S/internal/handler.go" <<'GO'

func (r *reconciler) expandPVC(ctx context.Context, pvc *corev1.PersistentVolumeClaim) error {
	return r.client.Patch(ctx, pvc, r.kube.Client().MergeFrom(pvc))
}
GO
passes
lacks "$OUT" "expandPVC"
pass

# Languages it does not read are named, for the model to read.
go_service java
mkdir -p "$S/src/main/java/shop"; echo 'class OrderImpl {}' > "$S/src/main/java/shop/OrderImpl.java"
passes
has "$OUT" "not checked: 1 Java file: read its handlers yourself"
pass

NAME=usage
if trace check "$TMP/missing"; then fail "a missing directory passed"; fi
has "$OUT" "not a directory"
if trace; then fail "no command passed"; fi
has "$OUT" "usage: looper-trace check"
pass

echo "looper-trace: all scenarios pass"
