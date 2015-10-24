immutable Tagger <: Model; forw; back; pred; params;
    function Tagger(forw::Net, back::Net, pred::Net; o...)
        par = vcat(params(forw), params(back), params(pred))
        new(forw, back, pred, par)
    end
end

params(m::Tagger)=m.params
reset!(m::Tagger)=(reset!(m.forw);reset!(m.back);reset!(m.pred))
test(m::Tagger, data, loss; o...)=(l=zeros(2); tagger_loop(m, data, loss; losscnt=l, o...); l[1]/l[2])
train(m::Tagger, data, loss; o...)=tagger_loop(m, data, loss; trn=true, o...)

function tagger_loop(m::Tagger, data, loss; gcheck=false, o...)
    x,ygold,mask = Any[],Any[],Any[]
    for item in data            # each item contains one (x,y,mask) triple for a minibatch of tokens for time t
        if item != nothing      
            push!(x, item[1]); push!(ygold, item[2]); push!(mask, item[3])
        else                    # or an item can be nothing marking sentence end
            reset!(m)
            yforw = tagger_forw(m.forw, x; o...)
            yback = reverse(tagger_forw(m.back, reverse(x); o...))
            ypred = tagger_forw(m.pred, yforw, yback; o...) # pred network should accept two inputs
            tagger_loss(ypred, ygold, mask, loss; o...)
            tagger_bptt(m, ygold, mask, loss; o...)
            gcheck && break     # only do one sentence and no update when gradient checking
            tagger_update(m; o...)
            empty!(x); empty!(ygold); empty!(mask)
        end
    end
end

function tagger_forw(net::Net, inputs...; o...)
    N = length(inputs[1])
    ystack = cell(N)
    for n=1:N
        ypred = forw(net, map(x->x[n], inputs)...; seq=true, o...)
        ystack[n] = copy(ypred)
    end
    return ystack
end

function tagger_loss(ypred, ygold, mask, loss; losscnt=nothing, lossreport=0, o...)
    losscnt==nothing && return
    (yrows, ycols) = size2(ypred[1])
    for i=1:length(ypred)
        @assert (yrows, ycols) == size2(ypred[i])
        ntoks = (mask[i] == nothing ? ycols : sum(mask[i]))
        losscnt[1] += loss(ypred[i], ygold[i]; mask=mask[i], o...)
        losscnt[2] += ntoks/ycols
    end
    if lossreport > 0 && losscnt[2]*ycols > lossreport
        println((exp(losscnt[1]/losscnt[2]), losscnt[1]*ycols, losscnt[2]*ycols))
        losscnt[1] = losscnt[2] = 0
    end
end

function tagger_bptt(m::Tagger, ygold, mask, loss; trn=false, o...)
    trn || return
    N=length(ygold)
    gforw,gback = cell(N),cell(N)
    for n=N:-1:1
        (gf, gb) = back(m.pred, ygold[n], loss; seq=true, mask=mask[n], getdx=true, o...)
        gforw[n],gback[n] = copy(gf),copy(gb)
    end
    for n=1:N
        back(m.back, gback[n]; seq=true, mask=mask[n], o...)
    end
    for n=N:-1:1
        back(m.forw, gforw[n]; seq=true, mask=mask[n], o...)
    end
end

function tagger_update(m::Tagger; gclip=0, trn=false, o...)
    trn || return
    if gclip > 0
        g = gnorm(m)
        gclip=(g > gclip > 0 ? gclip/g : 0)
    end
    update!(m; gclip=gclip, o...)
end