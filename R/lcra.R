
#' Bayesian Latent Class Analysis
#' 
#' Perform Bayesian LCA
#'
#' Given a set of categorical predictors, draw posterior distribution of 
#' probability of class membership for each observation.
#' 
#' @param formula If formula = NULL, LCA without regression model is fitted. If
#' a regression model is to be fitted, specify a formula using R standard syntax,
#' e.g., Y ~ age + sex + trt. Do not include manifest variables in the regression
#' model specification. These will be appended internally as latent classes.
#' @param family a description of the error distribution to 
#' be used in the model. Currently the options are c("gaussian") with identity 
#' link and c("binomial") which uses a logit link.
#' @param data
#' @param nclasses
#' @param manifest character vector containing the names of each manifest variable,
#' e.g., manifest = c("Z1", "med_3", "X5")
#' @param inits list of initial values for WinBUGS. Defaults will be set if nothing
#' is specified.
#' @param dir Specify full path to the directory where you want
#' to store the WinBUGS output files and BUGS model file.
#' @param ...
#' 
#' @return a named list of draws.
#'

lcra = function(formula, family, data, nclasses, manifest, inits, dir, 
                     n.chains, n.iter, parameters.to.save, ...) {
  
  # checks on input
  
  # check for valid formula?
  
  if(missing(data)) {
    stop("A data set is required to fit the model.")
  }
  
  if(!is.data.frame(data)) {
    stop("A data.frame is required to fit the model.")
  }
  
  if(missing(family)) {
    stop("Family must be specified. Currently the options are 'gaussian' (identity link) and 'binomial' which uses a logit link.")
  }
  
  if(missing(dir)) {
    dir = tempdir()
  }
  
  if(missing(formula)) {
    stop("Specify an R formula for the regression model to be fitted. 
         If you only want the latent class analysis, set formula = NULL.")
  }
  
  N = nrow(data)
  n_manifest = length(manifest)
  
  if(is.null(formula)) {do_regression = FALSE}
  else {do_regression = TRUE}
  
  # Convert all manifest variables to numeric 1,... nlevels?
  
  # construct a model frame (mf)
  
  mf = match.call(expand.dots = FALSE)
  m = match(c("formula", "data"), names(mf))
  mf = mf[c(1L, m)]
  mf[[1L]] = quote(stats::model.frame)
  mf = eval(mf, parent.frame())
  
  # construct a model matrix
  
  mt = attr(mf, "terms")
  x = model.matrix(mt, mf)
  
  # select manifest variables from model matrix
  if(any(!(manifest %in% colnames(data)))) {
    stop("At least one manifest variable name is not in the names of variables
         in the data set.")
  }
  
  Z = data[,manifest]
  
  unique.manifest.levels = unique(apply(Z, 2, function(x) {length(unique(x))}))
  p.length = length(unique.manifest.levels)
  
  pclass_prior = round(rep(1/nclasses, nclasses), digits = 3)
  if(sum(pclass_prior) != 1){
    pclass_prior[length(pclass_prior)] = pclass_prior[length(pclass_prior)] + 
      (1 - sum(pclass_prior))
  }
  
  dat_list = vector(mode = "list", length = 6)
  #name = vector(mode = "numeric", length = length(unique.manifest.levels))
  prior_mat = matrix(NA, nrow = length(unique.manifest.levels), 
                     ncol = max(unique.manifest.levels))
  for(j in 1:length(unique.manifest.levels)) {
    #name[j] = paste("prior", unique.manifest.levels[j], sep = "")
    prior = round(rep(1/unique.manifest.levels[j], unique.manifest.levels[j]), digits = 3)
    if(sum(prior) != 1){
      prior[length(prior)] = prior[length(prior)] + 
        (1 - sum(prior))
    }
    if(length(prior) < length(prior_mat[j,])) {
      fill = rep(NA, length = (length(prior_mat[j,]) - length(prior)))
      prior = c(prior, fill)
      prior_mat[j,] = prior
    } else {
      prior_mat[j,] = prior
    }
  }
  
  names(dat_list) = c("prior_mat", "prior", "Z", "C", "x", "nlevels")
  
  dat_list[["prior_mat"]] = structure(
    .Data=as.vector(prior_mat),
    .Dim=c(length(unique.manifest.levels), max(unique.manifest.levels))
  )
  
  dat_list[["prior"]] =  pclass_prior
  
  dat_list[["Z"]] = structure(
    .Data=as.vector(as.matrix(Z)),
    .Dim=c(N,n_manifest)
  )
  
  dat_list[["C"]] = structure(
    .Data=rep(0, (nclasses-1) * N),
    .Dim=c(N,nclasses-1)
  )
  
  dat_list[["x"]] = structure(
    .Data=x,
    .Dim=c(N,ncol(x))
  )
  
  nlevels = apply(Z, 2, function(x) {length(unique(x))})
  names(nlevels) = NULL
  dat_list[["nlevels"]] = nlevels
  
  # construct R2WinBUGS input
  n_beta = ncol(x)
  
  regression = c()
  response = c()
  
  if(family == "gaussian") {
    regression = expr(yhat[i] <- inprod(x[i,], beta[]) + inprod(C[i,], alpha[]))
    response = expr(y[i] ~ dnorm(yhat[i], tau))
  } else if(family == "binomial") {
    regression = expr(logit(p[i]) <- inprod(x[i,], beta[]) + inprod(C[i,], alpha[]))
    response = expr(Y[i]~dbern(p[i]))
  }
  
  # call R bugs model constructor
  model = constr_bugs_model(N = N, n_manifest = n_manifest, n_beta = n_beta,
                            nclasses = nclasses, npriors = unique.manifest.levels, 
                            regression = regression, response = response)
  # write model
  filename <- file.path(dir, "model.bug")
  write.model(model, filename)
  
  # Fit Bayesian latent class model
  samp_lca = bugs(data = dat_list, inits = inits,
                  model.file = filename, n.chains = n.chains, 
                  n.iter = n.iter, parameters.to.save = parameters.to.save, 
                  debug = TRUE)
  
  # Results
  # return bugs fit
  
  result = 
    list(model.frame = mf,
         model.matrix = x,
         bugs.object = samp_lca,
         model = model)
  
  attr(result, "class") = "lcra"
  
  return(result)
  
}



#' Contruct Bugs Model
#'
#' Construct bugs latent class model in the form of a function for use in the code
#' function bayes_lca
#'
#' @param x model matrix
#' @param regression Expression which contains code for the response distribution,
#' e.g. expr(stuff)
#'
#' @return R function which contains Bugs model

constr_bugs_model = function(N, n_manifest, n_beta, nclasses, npriors,
                             regression, 
                             response) {
  
  constructor = function() {
    
    bugs_model_enque = 
      quo({
        
        bugs_model_func = function() {
          
          for (i in 1:!!N){
            true[i]~dcat(theta[])
            
            for(j in 1:!!n_manifest){
              Z[i,j]~dcat(Zprior[true[i],j,1:nlevels[j]])
            }
            
            for(k in 2:(!!nclasses)) {
              C[i,k-1] <- step(-true[i]+k) - step(-true[i]+k-1)
            }

            !!regression
            !!response
          }
          
          theta[1:!!nclasses]~ddirch(prior[])
          
          # need to generalize to all prior""[], make a series of arrays
          for(c in 1:!!nclasses) {
            for(j in 1:!!npriors) {
              Zprior[c,j,1:nlevels[j]]~ddirch(prior_mat[j,1:nlevels[j]])
            }
          } # need one of these double loops for each prior length
          
          for(k in 1:!!n_beta) {
            beta[k]~dnorm(0,0.1)
          }
          
          for(k in 2:!!nclasses) {
            alpha[k-1]~dnorm(0,0.1)
          }
          
          tau~dgamma(0.1,0.1)
          
        }
      })
    
    return(bugs_model_enque)
  }
 
  text_fun = as.character(quo_get_expr(constructor()))[2]
  return(eval(parse(text = text_fun)))
  
}


#' Get the Bugs model
#'
#' Sometimes the user may want more flexibility in the model fit than 
#' our program provides. In this case, the user can fit a close model and 
#' use this function to retrieve the model as an R function. 
#'
#' @param fit an lcra fit object
#'
#' @return R function which contains Bugs model

get_bugs_model = function(fit) {
  if(class(fit) != "lcra") {
    stop("Must be a lcra object to extract the Bugs model.")
  }
  return(fit$model)
}




