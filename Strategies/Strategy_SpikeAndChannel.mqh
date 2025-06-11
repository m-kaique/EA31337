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
  int      m_atrHandle;      // ATR(14) handle
  int      m_ema9Handle;     // EMA(9)  handle
  int      m_ema50Handle;    // EMA(50) handle for HTF filter
  datetime m_lastBar;        // last processed bar time
  bool     m_spikeDetected;  // spike phase found
  int      m_spikeDir;       // spike direction 1/-1
  double   m_lineSlope;      // channel line slope
  double   m_lineIntercept;  // channel line intercept
  int      m_pullbacks;      // pullbacks count
  datetime m_channelStart;   // channel start time

 public:
  //--- constructor
  Stg_SpikeAndChannel()
      : m_atrHandle(INVALID_HANDLE), m_ema9Handle(INVALID_HANDLE),
        m_ema50Handle(INVALID_HANDLE), m_lastBar(0), m_spikeDetected(false),
        m_spikeDir(0), m_lineSlope(0), m_lineIntercept(0), m_pullbacks(0),
        m_channelStart(0) {}

  //--- initialization
  virtual bool OnInit() {
    Set(STRAT_PARAM_NAME, "SpikeAndChannel");
    m_atrHandle   = iATR(NULL, PERIOD_CURRENT, 14);
    m_ema9Handle  = iMA(NULL, PERIOD_CURRENT, 9, 0, MODE_EMA, PRICE_CLOSE);
    m_ema50Handle = iMA(NULL, HTF, 50, 0, MODE_EMA, PRICE_CLOSE);
    m_lastBar     = 0;
    m_spikeDetected = false;
    m_spikeDir = 0;
    m_lineSlope = 0;
    m_lineIntercept = 0;
    m_pullbacks = 0;
    m_channelStart = 0;
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
    int dir = 0;
    double firstLow = 0, firstHigh = 0;
    for (int i = 3; i >= 1; i--) {
      double o = iOpen(NULL, PERIOD_CURRENT, i);
      double c = iClose(NULL, PERIOD_CURRENT, i);
      double h = iHigh(NULL, PERIOD_CURRENT, i);
      double l = iLow(NULL, PERIOD_CURRENT, i);
      int cd = (c > o) ? 1 : -1;
      if (dir == 0)
        dir = cd;
      if (dir != cd)
        return false;
      if (MathAbs(c - o) < 0.75 * (h - l))
        return false;
      if (i < 3) {
        double po = iOpen(NULL, PERIOD_CURRENT, i + 1);
        double pc = iClose(NULL, PERIOD_CURRENT, i + 1);
        double top1 = MathMax(o, c);
        double bot1 = MathMin(o, c);
        double top2 = MathMax(po, pc);
        double bot2 = MathMin(po, pc);
        double overlap = MathMin(top1, top2) - MathMax(bot1, bot2);
        if (overlap > 0.25 * (top2 - bot2))
          return false;
      }
      if (i == 3) {
        firstLow = l;
        firstHigh = h;
      }
    }
    double vol = iVolume(NULL, PERIOD_CURRENT, 1);
    if (vol < MedianVolume(20))
      return false;
    m_spikeDir = dir;
    m_spikeDetected = true;
    m_channelStart = iTime(NULL, PERIOD_CURRENT, 1);
    m_pullbacks = 0;
    m_lineSlope = 0;
    m_lineIntercept = 0;
    return true;
  }

  //--- determine if channel is still valid
  bool IsChannel() {
    if (!m_spikeDetected)
      return false;

    // Build simple trend line from spike extremes
    double refPrice1 = (m_spikeDir > 0) ? iLow(NULL, PERIOD_CURRENT, 3)
                                        : iHigh(NULL, PERIOD_CURRENT, 3);
    double refPrice2 = (m_spikeDir > 0) ? iLow(NULL, PERIOD_CURRENT, 1)
                                        : iHigh(NULL, PERIOD_CURRENT, 1);
    m_lineSlope = (refPrice2 - refPrice1) / (2 * PeriodSeconds());
    m_lineIntercept = refPrice1 - m_lineSlope * iTime(NULL, PERIOD_CURRENT, 3);
    double angle = MathArctan(m_lineSlope / Point) * 180.0 / M_PI;
    if (MathAbs(angle) < 15.0)
      return false;

    // check last pullback touches
    datetime t1 = iTime(NULL, PERIOD_CURRENT, 1);
    double linePrice = m_lineSlope * t1 + m_lineIntercept;
    double lastLow = iLow(NULL, PERIOD_CURRENT, 1);
    double lastHigh = iHigh(NULL, PERIOD_CURRENT, 1);
    if ((m_spikeDir > 0 && lastLow <= linePrice) ||
        (m_spikeDir < 0 && lastHigh >= linePrice)) {
      m_pullbacks++;
    }

    m_channelStart = (m_channelStart == 0) ? t1 : m_channelStart;
    if (m_pullbacks >= 3)
      return true;

    return false;
  }

  //--- failing pullback detection
  bool IsPullbackFail() {
    if (!m_spikeDetected || m_lineSlope == 0)
      return false;

    datetime t1 = iTime(NULL, PERIOD_CURRENT, 1);
    double line = m_lineSlope * t1 + m_lineIntercept;
    double lastLow = iLow(NULL, PERIOD_CURRENT, 1);
    double lastHigh = iHigh(NULL, PERIOD_CURRENT, 1);

    if (m_spikeDir > 0 && lastLow > line)
      return true;
    if (m_spikeDir < 0 && lastHigh < line)
      return true;

    return false;
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
    if (!m_spikeDetected)
      return false;

    double impulse = MathAbs(iClose(NULL, PERIOD_CURRENT, 1) -
                             iOpen(NULL, PERIOD_CURRENT, 3));
    double pullback = MathAbs(iClose(NULL, PERIOD_CURRENT, 0) -
                              iClose(NULL, PERIOD_CURRENT, 1));
    if (pullback > 0.38 * impulse)
      return false;

    if (IsPullbackFail()) {
      OpenTrade(m_spikeDir);
      m_spikeDetected = false;
      return true;
    }
    return false;
  }

  //--- open channel entry
  void EnterChannel() {
    if (!m_spikeDetected || !IsChannel())
      return;
    if (ReversalBar(1)) {
      OpenTrade(m_spikeDir);
      m_spikeDetected = false;
    }
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
    for (int i = PositionsTotal() - 1; i >= 0; --i) {
      if (!PositionSelectByIndex(i))
        continue;
      if (PositionGetSymbol(i) != _Symbol)
        continue;
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double stop  = PositionGetDouble(POSITION_SL);
      double vol   = PositionGetDouble(POSITION_VOLUME);
      int type     = (int)PositionGetInteger(POSITION_TYPE);
      double rr = 0;
      if (type == POSITION_TYPE_BUY)
        rr = (Bid - entry) / (entry - stop);
      else
        rr = (entry - Ask) / (stop - entry);

      if (rr >= 1.0 && vol > 0.0) {
        if (rr >= 2.0 && vol > 0.2)
          ClosePosition(PositionGetTicket(i), vol * 0.3);
        else if (rr >= 1.0)
          ClosePosition(PositionGetTicket(i), vol * 0.5);

        double trail = (type == POSITION_TYPE_BUY ? Bid : Ask) -
                       m_spikeDir * TrailStepPips * Point;
        ModifyPosition(PositionGetTicket(i), trail);
      }

      if ((TimeCurrent() - PositionGetInteger(POSITION_TIME)) /
              PeriodSeconds() > BarsTimeout)
        ClosePosition(PositionGetTicket(i));
    }
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
    double prevH = iHigh(NULL, PERIOD_CURRENT, shift + 1);
    double prevL = iLow(NULL, PERIOD_CURRENT, shift + 1);

    bool engulf = (m_spikeDir > 0 && c > prevH) || (m_spikeDir < 0 && c < prevL);
    bool pinbar = ((h - MathMax(c, o)) > 2 * (MathMin(c, o) - l)) && (m_spikeDir > 0 ? c > o : c < o);
    bool closeBreak = (m_spikeDir > 0 && c > prevH) || (m_spikeDir < 0 && c < prevL);

    return (engulf || pinbar || closeBreak);
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
    if (!m_spikeDetected)
      return;
    color col = (m_spikeDir > 0) ? clrGreen : clrRed;
    ObjectCreate(0, "SpikeLine", OBJ_TREND, 0, m_channelStart,
                 (m_spikeDir > 0 ? iLow(NULL, PERIOD_CURRENT, 3)
                                   : iHigh(NULL, PERIOD_CURRENT, 3)),
                 TimeCurrent(),
                 (m_spikeDir > 0 ? iLow(NULL, PERIOD_CURRENT, 1)
                                   : iHigh(NULL, PERIOD_CURRENT, 1)));
    ObjectSetInteger(0, "SpikeLine", OBJPROP_COLOR, col);
  }
};

} // namespace Strategies

//+------------------------------------------------------------------+
