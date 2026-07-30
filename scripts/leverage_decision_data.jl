#!/usr/bin/env julia
# Regenerates the data for docs/leverage_decision.html: the validated spine levered x1/x1.5/x2/x3
# on the daily panel (2007-2026), weekly-sampled equity + drawdown, at 3% financing on the
# borrowed portion. Writes JSON to ARGS[1] (default /tmp/leverage_viz.json). Re-inject with:
#   python3 -c "..."  (see docs note) OR the commit that added the visual.
using DelimitedFiles, Dates, Statistics, LinearAlgebra, JSON3
const REPO = normpath(joinpath(@__DIR__, ".."))
include(joinpath(REPO, "src/module_13_portfolio/module_13_portfolio.jl")); using .PortfolioOptModule

function build(outpath)
    raw,_ = readdlm(joinpath(REPO,"scripts/data/sector_panel.csv"), Char(44); header=true)
    dts=Date.(string.(raw[:,1])); px=Float64.(raw[:,2:end]); R=simple_returns(px); dR=dts[2:end]; T,N=size(R)
    st=SpineState(N; base=:invvol, regime=:dd); prev=zeros(N); pnl=zeros(T)
    for t in 252:T-1
        w=spine_step!(st,@view R[t-251:t,:]); turn=sum(abs,w.-prev); prev=w
        pnl[t+1]=dot(w,@view R[t+1,:])-0.0002*turn
    end
    sl=findall(>=(Date(2007,2,1)),dR); r=pnl[sl]; d=dR[sl]; FIN=0.03
    ser(L)=(rl=L.*r .- (L-1)*(FIN/252); eq=cumprod(1 .+rl); dd=eq./accumulate(max,eq).-1; (rl,eq,dd))
    widx=collect(1:5:length(d))
    data=Dict{String,Any}("dates"=>[string(d[i]) for i in widx],"series"=>Dict{String,Any}(),"stats"=>Dict{String,Any}())
    for (nm,L) in (("x1",1.0),("x1_5",1.5),("x2",2.0),("x3",3.0))
        rl,eq,dd=ser(L)
        data["series"][nm]=Dict("equity"=>[round(eq[i],digits=4) for i in widx],"dd"=>[round(100*dd[i],digits=2) for i in widx])
        data["stats"][nm]=Dict("cagr"=>round(100*(prod(1 .+rl)^(252/length(rl))-1),digits=1),
            "maxdd"=>round(100*minimum(dd),digits=1),"sharpe"=>round((mean(rl)*252)/(std(rl)*sqrt(252)),digits=2),
            "final"=>round(eq[end],digits=1))
    end
    data["crises"]=[Dict("name"=>"GFC 08–09","start"=>"2007-10-01","stop"=>"2009-06-30"),
                    Dict("name"=>"COVID","start"=>"2020-02-15","stop"=>"2020-05-01"),
                    Dict("name"=>"2022","start"=>"2022-01-01","stop"=>"2022-10-31")]
    write(outpath, JSON3.write(data))
    @info "wrote leverage viz data" outpath points=length(widx) x1=data["stats"]["x1"]["final"] x3=data["stats"]["x3"]["final"]
end

build(get(ARGS, 1, "/tmp/leverage_viz.json"))
