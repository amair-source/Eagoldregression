# QuantumMathAI V6 Guardian

Mean-reversion Expert Advisor for MetaTrader 5 (XAUUSD / gold), using a linear-regression channel-breakout entry.

## Strategy (V6, final validated config)
- Timeframe: M3
- Entry: 34-bar linear regression; enter when the prior bar pierces the 2-sigma channel and closes back inside, with trend confirmation from a 100-bar filter
- Filters: R-squared >= 0.5, |slope| >= 0.05, spread cap, 08:00-22:00 server window, max 1 position
- SL: ATR(14) x 2.0
- TP: fixed RR 4.0
- Risk: 0.5% per trade, capped at min-lot rules
- Magic number: 66666

## Files
- `QuantumMathAI_V6_Guardian.mq5` - EA source
- `QuantumMathAI_V6_Guardian.ex5` - compiled EA
- `V6_Guardian_LOT10.tpl` - MT5 chart template (ready to apply to an XAUUSD M3 chart)
- `live_audit.md` - full development/deployment audit log

## Live config (verified)
| Parameter | Value |
|---|---|
| LRC_Period | 34 |
| Slope_Threshold | 0.05 |
| R_Squared_Min | 0.5 |
| RiskPercent | 0.5 |
| ATR_Multiplier_SL | 2.0 (SL_Mode 0) |
| UseFixedRR / FixedRR | 1 / 4.0 |
| MaxPositions | 1 |
| TrendFilterPeriod | 100 |
| MagicNumber | 66666 |

## Backtest (XAUUSD M3, 2025-09-01..2026-08-31, deposit 4000)
PF 1.0067, +$62.24, 691 trades, WR 24.2%, maxDD 17.28%, expected payoff +$0.09/trade