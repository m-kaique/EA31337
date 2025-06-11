#include "../src/include/includes.h"
#include "Strategy_SpikeAndChannel.mqh"

Stg_SpikeAndChannel strategy;

int OnInit(){
  return strategy.OnInit() ? INIT_SUCCEEDED : INIT_FAILED;
}
void OnDeinit(const int reason){
  strategy.OnDeinit(reason);
}
void OnTick(){
  strategy.OnTick();
}
