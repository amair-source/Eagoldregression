<chart>
id=38929335560252
symbol=XAUUSD
description=Gold vs US Dollar
period_type=0
period_size=3
digits=3
tick_size=0.000000
position_time=0
scale_fix=0
scale_fix11=0
scale_bar=0
scale_bar_val=1.000000
scale=16
mode=1
fore=0
grid=1
volume=1
scroll=0
shift=0
shift_size=15.151515
fixed_pos=0.000000
ohlc=1
bidline=1
askline=0
lastline=0
days=0
descriptions=0
window_left=0
window_top=0
window_right=0
window_bottom=0
window_type=1
background_color=0
foreground_color=16777215
barup_color=65280
bardown_color=65280
bullcandle_color=0
bearcandle_color=16777215
chartline_color=65280
volumes_color=3329330
grid_color=10061943
bidline_color=10061943
askline_color=255
lastline_color=49152
stops_color=255

<expert>
name=QuantumMathAI_V6_Guardian
path=Experts\QuantumMathAI_V6_Guardian.ex5
expertmode=1
<inputs>
--- 1. Quantum Math Settings ---=
LRC_Period=34
Slope_Threshold=0.05
R2_Max=0.5
BandMultiplier=2.0
--- 2. Risk Management ---=
RiskPercent=0.5
FixedLot=0.0
ATR_Period=14
ATR_Multiplier_SL=2.0
PartialRR=2.0
PartialPct=50.0
BERR=1.0
TPRR=4.0
MaxPositions=1
MaxHoldMinutes=480
--- 2b. Optional Trend Confluence ---=
UseTrendConfluence=0
--- 3. Auto News Filter (ForexFactory) ---=
UseAutoNews=1
IncludeMedium=0
PauseMinsBefore=30
PauseMinsAfter=30
ServerTimeOffset=2
--- 4. Filters & Time ---=
MaxSpreadPoints=150
StartHour=8
EndHour=22
--- 5. System ---=
MagicNumber=66666
</inputs>
</expert>

<window>
height=100.000000

<indicator>
name=Main
path=
apply=1
show_data=1
scale_inherit=0
scale_line=0
scale_line_percent=50
scale_line_value=0.000000
scale_fix_min=0
scale_fix_min_val=0.000000
scale_fix_max=0
scale_fix_max_val=0.000000
expertmode=0
fixed_height=-1
</indicator>
</window>
</chart>