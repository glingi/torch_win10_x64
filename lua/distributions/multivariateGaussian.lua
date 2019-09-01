distributions.mvn = {}

function distributions.mvn.logpdf(x, mu, sigma, options)
    options = options or {}
    x = torch.Tensor(x)
    mu = torch.Tensor(mu)
    sigma = torch.Tensor(sigma)

    -- If any input is vectorised, we return a vector. Otherwise remember that we should return scalar.
    local scalarResult = (x:dim() == 1) and (mu:dim() == 1)

    -- Now make our inputs all vectors, for simplicity
    if x:dim() == 1 then
        x = x:view(1, x:nElement())
    end
    if mu:dim() == 1 then
        mu = mu:view(1, mu:nElement())
    end

    -- Expand any 1-row inputs so that we have matching sizes
    local nResults
    if x:size(1) == 1 and mu:size(1) ~= 1 then
        nResults = mu:size(1)
        x = x:expand(nResults, x:size(2))
    elseif x:size(1) ~= 1 and mu:size(1) == 1 then
        nResults = x:size(1)
        mu = mu:expand(nResults, mu:size(2))
    else
        if x:size(1) ~= mu:size(1) then
            error("x and mu should have the same number of rows")
        end
        nResults = x:size(1)
    end

    x = x:clone():add(-1, mu)

    local logdet
    local transformed
    local decomposed

    -- For a diagonal covariance matrix, we allow passing a vector of the diagonal entries
    if sigma:dim() == 1 then
        local D = sigma:size(1)
        decomposed = sigma:clone()
        if not options.cholesky then
            decomposed:sqrt()
        end
        transformed = torch.cdiv(x, decomposed:view(1, D):expand(nResults, D))
        logdet = decomposed:log():sum()
    else
        if not options.cholesky then
            decomposed = torch.potrf(sigma):triu() -- TODO remove triu as torch will be fixed
        else
            decomposed = sigma
        end
        transformed = torch.gesv(x:t(), decomposed:t()):t()
        logdet = decomposed:diag():log():sum()
    end
    transformed:apply(function(a) return distributions.norm.logpdf(a, 0, 1) end)
    local result = transformed:sum(2) - logdet -- by independence
    if scalarResult then
        return result[1][1]
    else
        return result
    end
end

function distributions.mvn.pdf(...)
    local r = distributions.mvn.logpdf(...)
    if type(r) == 'number' then
        return math.exp(r)
    else
        return r:exp()
    end
end

function distributions.mvn.rnd(...)
    local nArgs = select("#", ...)
    local resultTensor

    local n -- number of samples
    local d -- number of dimensions for the Gaussian
    local mu -- mean
    local sigma -- covariance matrix

    local diagonalVariance = false -- do we face a diagonal covvariance matrix?
    local vectorOutput = false -- shall we return a vector instead of a matrix?

    local function inferDimension(sigma)
        if sigma:dim() == 1 then
            -- diagonal, and only one covariance matrix
            return sigma:size(1)
        else
            return sigma:size(2)
        end
        return d
    end

    local options = {}
    -- Is the last argument an options table?
    if type(select(nArgs, ...)) == 'table' then
        options = select(nArgs, ...)
        nArgs = nArgs - 1
    end

    if nArgs == 2 then -- mu, sigma only: return one sample
        -- TODO: Fix this. We should return as many samples as indicated by the NxD mu or the NxDxD sigma.
        n = 1
        mu = torch.Tensor(select(1, ...))
        sigma = torch.Tensor(select(2, ...))
        d = inferDimension(sigma)
        resultTensor = torch.Tensor(d)

    elseif nArgs == 3 then -- RESULT, mu, sigma - where result is either a number or an output tensor
        local resultInfo = select(1, ...)
        mu = torch.Tensor(select(2, ...))
        sigma = torch.Tensor(select(3, ...))

        -- Number of parameters is dictated by result
        if type(resultInfo) == 'number' then
            n = resultInfo
            d = -1 -- we do not know the dimension yet
        elseif distributions._isTensor(resultInfo) then
            resultTensor = resultInfo
            if resultTensor:dim() == 1 then
                -- vector D: only one sample asked for
                n = 1
                d = resultTensor:size(1)
                vectorOutput = true
            elseif resultTensor:dim() == 2 then
                -- 2D matrix: NxD
                n = resultTensor:size(1)
                d = resultTensor:size(2)
            else
                error('Result tensor must be a vector or a 2D matrix')
            end
        else
            error("Unable to understand first argument for mvn.rnd - should be an integer number of samples to be returned, or a result tensor, not a " .. type(resultInfo))
        end

        -- Now check if mu is compatible with result
        local nParams
        if mu:dim() == 1 then
            -- vector: D
            if d > 0 then
                assert(mu:size(1) == d, 'Number of elements of vector mu (' .. mu:size(1) .. ') does not match dimension of result (' .. d ..')')
            else
                d = mu:size(1)
            end
            mu = mu:view(1, d)
        elseif mu:dim() == 2 then
            assert(mu:size(1) == 1 or mu:size(1) == n, 'Number of rows of matrix mu (' .. mu:size(1) .. ') does not match that of result matrix (' .. n .. ')')
            if d > 0 then
                assert(mu:size(2) == d, 'Number of colums of matrix mu (' .. mu:size(2) .. ') does not match that of result matrix (' .. d ..')')
            else
                d = mu:size(2)
            end
        else
            error('mu must be 1D or 2D, not ' .. mu:dim() .. 'D')
        end

        -- Check if sigma is compatible with result and mu
        if sigma:dim() == 1 then
            -- Diagonal matrix
            assert(sigma:size(1) == d, 'Number of elements of vector sigma (' .. sigma:size(1) .. ') does not match dimension of result (' .. d .. ')')
            diagonalVariance = true
        elseif sigma:dim() == 2 then
            -- TODO: deal with Dx1
            if n == d then
                -- N == D, the matrix sigma is ambiguous and need clarification in the options
                if sigma:size(1) == n and  sigma:size(1) == d then
                    if options.diagonal == nil then
                        error('Ambiguous size for sigma: do you have N==D diagonal matrices of size D, or one DxD matrix? Please set options.diagonal to true or false to remove ambiguity')
                    end
                    diagonalVariance = options.diagonal
                end
            else
                -- N != D, 2D sigma is either DxD or NxD diagonal matrix
                if sigma:size(1) == d then
                    -- One single DxD full covariance matrix
                    diagonalVariance = false
                elseif sigma:size(1) == 1 then
                    -- 1 diagonal covariance
                elseif sigma:size(1) == n then
                    -- N diagonal covariances
                    diagonalVariance = true
                else
                    error('Number of rows of matrix sigma (' .. sigma:size(1) .. ') does not match either number of results (' .. n .. ') or dimension (' .. d .. ')')
                end
                assert(sigma:size(2) == d, 'Number of columns of matrix sigma (' .. sigma:size(2) .. ') does not match dimension of result (' .. d .. ')')
            end
        elseif sigma:dim() == 3 then
            -- NxDxD tensor
            assert(sigma:size(1) == n, '1st dimension of 3D sigma (' .. sigma:size(1) ..') does not match number of results (' .. n .. ')')
            assert(sigma:size(2) == d, '2nd dimension of 3D sigma (' .. sigma:size(2) ..') does not match dimension of results (' .. d .. ')')
            assert(sigma:size(3) == d, '3rd dimension of 3D sigma (' .. sigma:size(3) ..') does not match dimension of results (' .. d .. ')')
            diagonalVariance = false
        else
            error('sigma must be D, NxD, or NxDxD, not ' .. sigma:dim() .. 'D')
        end
    else
        error("Invalid arguments for mvn.rnd().\
        Expecting [N|ResultTensor,] mu, sigma [, options].")
    end

    -- Now make our inputs all tensors, for simplicity
    if not resultTensor then
        resultTensor = torch.Tensor(n, d)
    end

    if mu:dim() == 1 then
        mu = mu:view(1, mu:nElement())
    end
    -- TODO: use the flag diagonalVariance rather than checking sigma's size once again
    if sigma:dim() == 1 then
        if mu:size(2) ~= sigma:size(1) then
            error("mvn.rnd: inconsistent sizes for mu and sigma")
        end
        sigma = sigma:view(1, d)
    elseif sigma:dim() == 2 then
        -- either 1xD or DxD or NxD
        if sigma:size(1) ~= 1 then
            if sigma:size(1) == sigma:size(2) then
                if n == d then
                    error("mvn.rnd: ambiguous covariance input")
                end
            end

            if mu:size(2) ~= sigma:size(1) or mu:size(2) ~= sigma:size(2) then
                error("mvn.rnd: inconsistent sizes for mu and sigma")
            end
            sigma = sigma:view(1, d, d)
        end
    elseif sigma:dim() == 3 then
        if mu:size(2) ~= d or sigma:size(2) ~= d or sigma:size(3) ~= d then
            error("mvn.rnd: inconsistent sizes for mu and sigma")
        end
    end
    if mu:size(1) == 1 then
        mu = mu:expand(n, d)
    end

    local function sampleFromDistribution(resultTensor, x, mu, sigma)
        local resultSize = resultTensor:size()
        local y
        if sigma:dim() == 2 then
            -- TODO: when Lapack's pstrf will be wrapped in Torch,
            -- use that instead of Cholesky with SVD failsafe
            if options.cholesky then
                y = torch.mm(x, sigma)
            else
                local fullRank, decomposed = pcall(function() return torch.potrf(sigma):triu() end)
                if fullRank then
                    -- Definite positive matrix: use Cholesky
                    y = torch.mm(x, decomposed)
                else
                    -- Rank-deficient matrix: fall back on SVD
                    local u, s, v = torch.svd(sigma)
                    local tmp = torch.cmul(x, s:sqrt():view(1, d):expand(n, d))
                    y = torch.mm(tmp, v:t())
                end
            end

        else
            -- diagonal sigma
            local decomposed
            decomposed = sigma:clone()
            if not options.cholesky then
                decomposed:sqrt()
            end
            y = torch.cmul(decomposed:view(1,d):expand(n,d), x)
        end

        resultTensor = resultTensor:add(y, mu):view(resultSize)
        return resultTensor
    end

    local x = torch.Tensor(n,d)
    randomkit.gauss(x)
    if sigma:size(1) == 1 then
        resultTensor = sampleFromDistribution(resultTensor, x, mu, sigma[1])
        return resultTensor
    else
        for k = 1, n do
            resultTensor[k] = sampleFromDistribution(resultTensor[k],
                                             x:narrow(1, k, 1), mu[k], sigma[k])
        end
        return resultTensor
    end
end

-- Return the entropy of a multivariate normal.
-- Just takes the covariance as a parameter, since it's independent of the mean
function distributions.mvn.entropy(sigma)
    local ndim = sigma:size(1)
    assert(sigma:dim() == 2)
    assert(sigma:size(2) == ndim)
    assert(distributions.util.isposdef(sigma))

    return ndim * (1 + torch.log(2*math.pi)) / 2
            + distributions.util.logdet(sigma) / 2
end

-- KL[p || q], p and q both multivariate normal
-- Takes two tables, each with field mu and sigma
-- and optional field lambda for the precision
function distributions.mvn.kl(q, p)
    assert(q.mu)
    assert(q.sigma)

    assert(p.mu)
    assert(p.sigma or p.lambda)

    local ndim = q.mu:size(1)
    assert(q.mu:dim() == 1)
    assert(distributions.util.isposdef(q.sigma))

    assert(p.mu:size(1) == ndim)
    assert(p.mu:dim() == 1)

    local lambda_p
    if p.lambda and
            pcall(distributions.util.isposdef, p.lambda) then
        lambda_p = p.lambda
    elseif pcall(distributions.util.isposdef, p.sigma) then
        lambda_p = torch.inverse(p.sigma)
    else
        error("Second argument has neither covriance nor precision")
    end

    local function qf(A,x) return torch.dot(x, torch.mv(A,x)) end
    return (torch.dot(lambda_p, q.sigma)
        + qf(lambda_p, p.mu - q.mu)
        - ndim
        - distributions.util.logdet(lambda_p)
        - distributions.util.logdet(q.sigma)) / 2
end
