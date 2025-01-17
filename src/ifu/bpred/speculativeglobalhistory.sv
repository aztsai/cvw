///////////////////////////////////////////
// speculativeglobalhistory.sv
//
// Written: Shreya Sanghai
// Email: ssanghai@hmc.edu
// Created: March 16, 2021
// Modified: 
//
// Purpose: Global History Branch predictor with parameterized global history register
// 
// A component of the CORE-V-WALLY configurable RISC-V project.
// 
// Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file 
// except in compliance with the License, or, at your option, the Apache License version 2.0. You 
// may obtain a copy of the License at
//
// https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the 
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
// either express or implied. See the License for the specific language governing permissions 
// and limitations under the License.
////////////////////////////////////////////////////////////////////////////////////////////////

`include "wally-config.vh"

module speculativeglobalhistory #(parameter int k = 10 ) (
  input logic             clk,
  input logic             reset,
  input logic             StallF, StallD, StallE, StallM, StallW, 
  input logic             FlushD, FlushE, FlushM, FlushW,
  output logic [1:0]      DirPredictionF, 
  output logic            DirPredictionWrongE,
  // update
  input logic             BranchInstrF, BranchInstrD, BranchInstrE, BranchInstrM, BranchInstrW,
  input logic [3:0]       WrongPredInstrClassD, 
  input logic             PCSrcE
);

  logic                    MatchF, MatchD, MatchE;
  logic                    MatchNextX, MatchXF;

  logic [1:0]              TableDirPredictionF, DirPredictionD, DirPredictionE;
  logic [1:0]              NewDirPredictionF, NewDirPredictionD, NewDirPredictionE;

  logic [k-1:0]            GHRF;
  logic 				   GHRExtraF;
  logic [k-1:0] 		   GHRD, GHRE, GHRM, GHRW;
  logic [k-1:0] 		   GHRNextF;
  logic [k-1:0] 		   GHRNextD;
  logic [k-1:0] 		   GHRNextE, GHRNextM, GHRNextW;
  logic [k-1:0]            IndexNextF, IndexF;
  logic [k-1:0]            IndexD, IndexE;
  

  logic [1:0]              ForwardNewDirPrediction, ForwardDirPredictionF;
  
  assign IndexNextF = GHRNextF;
  assign IndexF = GHRF;
  assign IndexD = GHRD[k-1:0];
  assign IndexE = GHRE[k-1:0];
      
  ram2p1r1wbe #(2**k, 2) PHT(.clk(clk),
    .ce1(~StallF | reset), .ce2(~StallM & ~FlushM),
    .ra1(IndexNextF),
    .rd1(TableDirPredictionF),
    .wa2(IndexE),
    .wd2(NewDirPredictionE),
    .we2(BranchInstrE & ~StallM & ~FlushM),
    .bwe2(1'b1));

  // if there are non-flushed branches in the pipeline we need to forward the prediction from that stage to the NextF demi stage
  // and then register for use in the Fetch stage.
  assign MatchF = BranchInstrF & ~FlushD & (IndexNextF == IndexF);
  assign MatchD = BranchInstrD & ~FlushE & (IndexNextF == IndexD);
  assign MatchE = BranchInstrE & ~FlushM & (IndexNextF == IndexE);
  assign MatchNextX = MatchF | MatchD | MatchE;

  flopenr #(1) MatchReg(clk, reset, ~StallF, MatchNextX, MatchXF);

  assign ForwardNewDirPrediction = MatchF ? NewDirPredictionF :
                                   MatchD ? NewDirPredictionD :
                                   NewDirPredictionE ;
  
  flopenr #(2) ForwardDirPredicitonReg(clk, reset, ~StallF, ForwardNewDirPrediction, ForwardDirPredictionF);

  assign DirPredictionF = MatchXF ? ForwardDirPredictionF : TableDirPredictionF;

  // DirPrediction pipeline
  flopenr #(2) PredictionRegD(clk, reset, ~StallD, DirPredictionF, DirPredictionD);
  flopenr #(2) PredictionRegE(clk, reset, ~StallE, DirPredictionD, DirPredictionE);

  // New prediction pipeline
  assign NewDirPredictionF = {DirPredictionF[1], DirPredictionF[1]};
  
  flopenr #(2) NewPredDReg(clk, reset, ~StallD, NewDirPredictionF, NewDirPredictionD);
  satCounter2 BPDirUpdateE(.BrDir(PCSrcE), .OldState(DirPredictionE), .NewState(NewDirPredictionE));

  // GHR pipeline
  // this version fails the regression test do to pessimistic x propagation.
  // assign GHRNextF = FlushD | DirPredictionWrongE ?  GHRNextD[k-1:0] :
  //                  BranchInstrF ? {DirPredictionF[1], GHRF[k-1:1]} :
  //                  GHRF;

  always_comb begin
	if(FlushD | DirPredictionWrongE) begin
	  GHRNextF = GHRNextD[k-1:0];
	end else if(BranchInstrF) GHRNextF = {DirPredictionF[1], GHRF[k-1:1]};
	else GHRNextF = GHRF;
  end

  flopenr  #(k) GHRFReg(clk, reset, (~StallF) | FlushD, GHRNextF, GHRF);	
  flopenr  #(1) GHRFExtraReg(clk, reset, (~StallF) | FlushD, GHRF[0], GHRExtraF);

  // use with out instruction class prediction
  //assign GHRNextD = FlushD ? GHRNextE[k-1:0] : GHRF[k-1:0];
  // with instruction class prediction
  assign GHRNextD = (FlushD | DirPredictionWrongE) ? GHRNextE[k-1:0] :
					WrongPredInstrClassD[0] & BranchInstrD  ? {DirPredictionD[1], GHRF[k-1:1]} : // shift right
  					WrongPredInstrClassD[0] & ~BranchInstrD ? {GHRF[k-2:0], GHRExtraF}:       // shift left
					GHRF[k-1:0];

  flopenr  #(k) GHRDReg(clk, reset, (~StallD) | FlushD, GHRNextD, GHRD);

  assign GHRNextE = BranchInstrE & ~FlushM ? {PCSrcE, GHRD[k-2:0]} :   // if the branch is not flushed
					FlushE ? GHRNextM :                                // branch is flushed
					GHRD;
  flopenr  #(k) GHREReg(clk, reset, (~StallE) | FlushE, GHRNextE, GHRE);

  assign GHRNextM = FlushM ? GHRNextW : GHRE;
  flopenr  #(k) GHRMReg(clk, reset, (~StallM) | FlushM, GHRNextM, GHRM);

  assign GHRNextW = FlushW ? GHRW : GHRM;
  flopenr  #(k) GHRWReg(clk, reset, (BranchInstrW & ~StallW) | FlushW, GHRNextW, GHRW);
  
  assign DirPredictionWrongE = PCSrcE != DirPredictionE[1] & BranchInstrE;

endmodule
