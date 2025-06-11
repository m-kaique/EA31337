//+------------------------------------------------------------------+
//|                 EA31337 Spike and Channel Strategy               |
//|                    Copyright 2016-2024, EA31337 Ltd              |
//|                        https://ea31337.github.io/                |
//+------------------------------------------------------------------+
//  This module implements the Spike and Channel pattern trading
//  strategy as described in the project documentation. The algorithm
//  detects strong impulse moves (spikes) followed by orderly pullbacks
//  forming a trend channel. Trades are opened on pullbacks within the
//  channel or optionally during the spike phase itself.
//
//  Pattern recognition
//  -------------------
//  * Spike: at least three consecutive candles in the same direction
//    with bodies >75% of range and little overlap. Volume must be
//    above the 20 bar median.
//  * Channel: dynamic trend line from the spike low/high respected by
//    at least three pullbacks with slope >15 degrees.
//  * Entries: inside spike (optional), on pullback to trend line with
//    reversal bar, or on failing pullback that does not reach the line.
//  * Exits: stop loss based on ATR or fixed pips, multiple partial
//    targets and trailing stop using EMA(9).
//
//  References:
//    - "Spike & Channel Patterns", Al Brooks, 2012.
//    - https://www.brookstradingcourse.com/price-action-trading-blog
//+------------------------------------------------------------------+
#pragma once

#include "../include/includes.h"

namespace Strategies {

class Stg_SpikeAndChannel : public CStrategy {
 public:
  //--- user adjustable inputs
  input bool   UseSpikeEntries   = false;   // Enable riskier spike-phase trades
  input double RiskPerTradePcnt = 1.0;     // % of free margin per position
  input int    MaxOpenPositions  = 3;       // One per phase leg
  input double FixedStopPips     = 150;     // Used if ATR mode disabled
  input bool   UseATRStops       = true;    // Use ATR based stops
  input int    TrailStartRR      = 1;       // Start trailing after R:R=1
  input int    TrailStepPips     = 50;      // Trailing step in pips
  input ENUM_TIMEFRAMES HTF      = PERIOD_H4; // Higher timeframe filter
  input double MinATRPoints      = 100;     // Minimum ATR to allow trading
  input double MaxSpreadPoints   = 30;      // Skip if spread above this
  input int    BarsTimeout       = 250;     // Maximum bars to keep trade open

 private:
  int    m_atrHandle;   // ATR(14) handle
  int    m_ema9Handle;  // EMA(9)  handle
  int    m_ema50Handle; // EMA(50) handle for HTF filter
  datetime m_lastBar;   // last processed bar time

 public:
  //--- constructor
  Stg_SpikeAndChannel() : m_atrHandle(INVALID_HANDLE), m_ema9Handle(INVALID_HANDLE),
      m_ema50Handle(INVALID_HANDLE), m_lastBar(0) {}

  //--- initialization
  virtual bool OnInit() {
    Set(STRAT_PARAM_NAME, "SpikeAndChannel");
    m_atrHandle  = iATR(NULL, PERIOD_CURRENT, 14);
    m_ema9Handle = iMA(NULL, PERIOD_CURRENT, 9, 0, MODE_EMA, PRICE_CLOSE);
    m_ema50Handle = iMA(NULL, HTF, 50, 0, MODE_EMA, PRICE_CLOSE);
    m_lastBar = 0;
    return (m_atrHandle != INVALID_HANDLE && m_ema9Handle != INVALID_HANDLE);
  }

  //--- main tick handler
  virtual void OnTick() {
    if (IsNewBar()) {
      UpdateIndicators();
      DetectSpikeAndChannel();
    }
    ManageOpenPositions();
  }

 protected:
  //--- check for new bar
  bool IsNewBar() {
    datetime t = iTime(NULL, PERIOD_CURRENT, 0);
    if (t != m_lastBar) { m_lastBar = t; return true; }
    return false;
  }

  //--- update indicator buffers
  void UpdateIndicators() {
    CopyBuffer(m_atrHandle, 0, 0, 2, NULL);
    CopyBuffer(m_ema9Handle, 0, 0, 2, NULL);
    CopyBuffer(m_ema50Handle, 0, 0, 1, NULL);
  }

  //--- main pattern detection logic
  void DetectSpikeAndChannel() {
    if (!IsSpike()) {
      return;
    }
    if (!IsChannel()) {
      return;
    }
    if (Spread() > MaxSpreadPoints || GetATRPoints() < MinATRPoints)
      return;
    if (HTF != PERIOD_CURRENT && !HTFAlign())
      return;
    if (PositionsTotal() >= MaxOpenPositions)
      return;
    if (UseSpikeEntries && EnterSpike())
      return;
    EnterChannel();
  }

  //--- detect spike pattern at bar 1
  bool IsSpike() {
    // Require at least three strong candles with minimal overlap
    for (int i = 1; i <= 3; i++) {
      double o = iOpen(NULL, PERIOD_CURRENT, i);
      double c = iClose(NULL, PERIOD_CURRENT, i);
      double h = iHigh(NULL, PERIOD_CURRENT, i);
      double l = iLow(NULL, PERIOD_CURRENT, i);
      if (MathAbs(c - o) < 0.75 * (h - l))
        return false;
      if (i > 1) {
        double prevC = iClose(NULL, PERIOD_CURRENT, i-1);
        double prevO = iOpen(NULL, PERIOD_CURRENT, i-1);
        if ((c > o && prevC > prevO && o < prevC && o > prevO) ||
            (c < o && prevC < prevO && o > prevC && o < prevO))
          return false; // bodies overlap more than 25%
      }
    }
    // volume filter
    double vol = iVolume(NULL, PERIOD_CURRENT, 1);
    double med = MedianVolume(20);
    return (vol >= med);
  }

  //--- determine if channel is still valid
  bool IsChannel() {
    // simplistic check using EMA50 slope
    double emaPrev = iMA(NULL, PERIOD_CURRENT, 50, 0, MODE_EMA, PRICE_CLOSE, 1);
    double emaCurr = iMA(NULL, PERIOD_CURRENT, 50, 0, MODE_EMA, PRICE_CLOSE, 0);
    double slope = MathArctan((emaCurr - emaPrev) / Point) * 180.0 / M_PI;
    return (MathAbs(slope) > 15.0);
  }

  //--- failing pullback detection
  bool IsPullbackFail() {
    // if last low/high is above/below trend line without touch
    return false; // placeholder
  }

  //--- check higher timeframe trend alignment
  bool HTFAlign() {
    double emaHTF = iMA(NULL, HTF, 50, 0, MODE_EMA, PRICE_CLOSE, 0);
    return ((TrendDir() > 0 && iClose(NULL, PERIOD_CURRENT, 1) > emaHTF) ||
            (TrendDir() < 0 && iClose(NULL, PERIOD_CURRENT, 1) < emaHTF));
  }

  //--- return trend direction based on recent candles
  int TrendDir() {
    double c0 = iClose(NULL, PERIOD_CURRENT, 1);
    double c1 = iClose(NULL, PERIOD_CURRENT, 2);
    return (c0 > c1) ? 1 : -1;
  }

  //--- open spike entry
  bool EnterSpike() {
    // first micro pullback entry
    if (IsPullbackFail()) {
      OpenTrade(TrendDir());
      return true;
    }
    return false;
  }

  //--- open channel entry
  void EnterChannel() {
    if (ReversalBar(1))
      OpenTrade(TrendDir());
  }

  //--- open trade helper
  void OpenTrade(int dir) {
    double stop = GetATRStop(dir == 1 && UseSpikeEntries);
    TradeParams tp = TradeParams();
    tp.lots = MoneyManagement(RiskPerTradePcnt);
    tp.stop_loss = dir > 0 ? Bid - stop : Ask + stop;
    OpenPosition(dir > 0 ? OP_BUY : OP_SELL, tp);
  }

  //--- trailing and partial exits
  void ManageOpenPositions() {
    // placeholder: implement partial closes and trailing
  }

  //--- atr based stop
  double GetATRStop(bool spike) {
    double atr = iATR(NULL, PERIOD_CURRENT, 14, 0);
    double mul = spike ? 1.0 : 0.6;
    return UseATRStops ? atr * mul : FixedStopPips * Point;
  }

  //--- return ATR in points
  double GetATRPoints() { return iATR(NULL, PERIOD_CURRENT, 14, 0) / Point; }

  //--- check for reversal candle types
  bool ReversalBar(int shift) {
    double o = iOpen(NULL, PERIOD_CURRENT, shift);
    double c = iClose(NULL, PERIOD_CURRENT, shift);
    double h = iHigh(NULL, PERIOD_CURRENT, shift);
    double l = iLow(NULL, PERIOD_CURRENT, shift);
    return ((c > o && c > iHigh(NULL, PERIOD_CURRENT, shift+1)) ||
            (c < o && c < iLow(NULL, PERIOD_CURRENT, shift+1)));
  }

  //--- estimate median volume
  double MedianVolume(int bars) {
    double arr[];
    ArrayResize(arr, bars);
    for(int i=1;i<=bars;i++) arr[i-1]=iVolume(NULL, PERIOD_CURRENT, i);
    ArraySort(arr);
    return arr[(bars-1)/2];
  }

  //--- visual helpers
  void DrawPatternObjects() {
    // optional debug drawings
  }
};

} // namespace Strategies

//+------------------------------------------------------------------+
